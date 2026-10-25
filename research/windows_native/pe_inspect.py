#!/usr/bin/env python3
"""Bounded, read-only PE image inventory. Never loads or executes inspected code.

Reference: https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
This is an image inspector, not a Windows loader or a compatibility verdict.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import sys


MAX_FILE_BYTES = 256 * 1024 * 1024
MAX_FILES = 32
MAX_SECTIONS = 96
MAX_DIRECTORIES = 16
MAX_LIBRARIES = 1024
MAX_SYMBOLS_PER_LIBRARY = 4096
MAX_SYMBOLS = 32768
MAX_CALLBACKS = 1024
MAX_STRING_BYTES = 4096
MAX_METADATA_READ = 64 * 1024 * 1024
MAX_IMPORT_TEXT_BYTES = 1024 * 1024
MAX_JSON_BYTES = 16 * 1024 * 1024
HASH_CHUNK = 1024 * 1024
UINT32_END = 1 << 32

MACHINES = {0x14C: "x86", 0x8664: "x86_64", 0xAA64: "arm64",
            0xA641: "arm64ec", 0xA64E: "arm64x", 0x1C4: "armv7-thumb2"}
SUBSYSTEMS = {0: "unknown", 1: "native", 2: "windows-gui", 3: "windows-console",
              5: "os2-console", 7: "posix-console", 9: "windows-ce-gui",
              10: "efi-application", 11: "efi-boot-service-driver",
              12: "efi-runtime-driver", 13: "efi-rom", 14: "xbox",
              16: "windows-boot-application"}
DIRECTORY_NAMES = ["export", "import", "resource", "exception", "certificate",
                   "base-relocation", "debug", "architecture", "global-pointer",
                   "tls", "load-config", "bound-import", "iat", "delay-import",
                   "clr", "reserved"]
LIMITATIONS = [
    "Static declarations only; no executable, DLL, callback or entry point was run.",
    "LoadLibrary/GetProcAddress, plugins, packed or decrypted imports and statically linked code may be invisible.",
    "Dependencies are not opened or resolved, including API-set contracts and forwarded exports.",
    "Graphics names are hints, not evidence of feature use, GPU support, HDR, DLSS version or performance.",
    "Header versions are linker declarations, not a verified minimum Windows version.",
    "DRM, anti-cheat, shader model, CPU instruction requirements and complete Win32 behaviour are not determined.",
    "This strict subset accepts PE32/PE32+ images, not COFF objects, archives or every Windows-loader edge case.",
]


class PEError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def require(condition, code, message):
    if not condition:
        raise PEError(code, message)


def extent(start, length, limit, label):
    require(start >= 0 and length >= 0 and start <= limit and length <= limit - start,
            "out-of-bounds", label + " exceeds its containing range")
    return start + length


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


class Reader:
    """pread avoids loading the image into memory; no mmap/SIGBUS on truncation."""
    def __init__(self, fd, size):
        self.fd = fd
        self.size = size
        self.metadata_bytes = 0

    def read(self, offset, length):
        extent(offset, length, self.size, "File read")
        require(length <= HASH_CHUNK, "resource-limit", "Single read exceeds 1 MiB")
        self.metadata_bytes += length
        require(self.metadata_bytes <= MAX_METADATA_READ, "resource-limit",
                "Repeated metadata reads exceed the 64 MiB work budget")
        result = os.pread(self.fd, length, offset)
        require(len(result) == length, "file-changed", "File changed or was truncated during inspection")
        return result

    def unpack(self, fmt, offset):
        return struct.unpack(fmt, self.read(offset, struct.calcsize(fmt)))

    def sha256(self):
        digest = hashlib.sha256()
        for offset in range(0, self.size, HASH_CHUNK):
            length = min(HASH_CHUNK, self.size - offset)
            chunk = os.pread(self.fd, length, offset)
            require(len(chunk) == length, "file-changed", "File changed during hashing")
            digest.update(chunk)
        return digest.hexdigest()


class PEImage:
    def __init__(self, reader):
        self.r = reader
        self.sections = []
        self.directories = []
        self.symbol_count = 0
        self.library_count = 0
        self.text_bytes = 0
        self.warnings = []

    def virtual_region(self, rva, length=1):
        extent(rva, length, UINT32_END, "RVA")
        extent(rva, length, self.image_size, "RVA in image")
        if rva < self.header_size and rva + length <= self.header_size:
            return None
        for section in self.sections:
            start = section["virtualAddress"]
            if start <= rva and rva + length <= start + section["mappedSize"]:
                return section
        raise PEError("unmapped-rva", "RVA is outside a single mapped header or section range")

    def raw_span(self, rva, length=1):
        section = self.virtual_region(rva, length)
        if section is None:
            offset, available = rva, self.header_size - rva
        else:
            delta = rva - section["virtualAddress"]
            require(delta <= section["rawSize"] and length <= section["rawSize"] - delta,
                    "unbacked-rva", "RVA points to zero-fill or unbacked section data")
            offset = section["rawOffset"] + delta
            available = section["rawSize"] - delta
        extent(offset, length, self.r.size, "Mapped file range")
        return offset, available

    def rva_unpack(self, fmt, rva):
        offset, _ = self.raw_span(rva, struct.calcsize(fmt))
        return self.r.unpack(fmt, offset)

    def string(self, rva):
        offset, available = self.raw_span(rva)
        data = self.r.read(offset, min(available, MAX_STRING_BYTES + 1))
        end = data.find(b"\0")
        require(0 < end <= MAX_STRING_BYTES, "invalid-string",
                "Import string is empty, unterminated or exceeds 4096 bytes")
        require(all(32 <= byte <= 126 for byte in data[:end]), "invalid-string",
                "Import string must contain printable ASCII")
        self.text_bytes += end
        require(self.text_bytes <= MAX_IMPORT_TEXT_BYTES, "resource-limit", "Import names exceed the 1 MiB text budget")
        return data[:end].decode("ascii")

    def va_to_rva(self, va, length=1):
        require(va >= self.image_base, "invalid-va", "VA precedes the preferred image base")
        rva = va - self.image_base
        self.virtual_region(rva, length)
        return rva

    def directory(self, index):
        return self.directories[index] if index < len(self.directories) else (0, 0)

    def headers(self):
        require(self.r.read(0, 2) == b"MZ", "not-pe", "Missing DOS MZ signature")
        pe_offset, = self.r.unpack("<I", 0x3C)
        require(64 <= pe_offset <= 1024 * 1024, "resource-limit",
                "PE header offset must be between 64 bytes and 1 MiB")
        require(self.r.read(pe_offset, 4) == b"PE\0\0", "not-pe", "Missing PE signature")
        machine, count, timestamp, _, _, opt_size, characteristics = self.r.unpack("<HHIIIHH", pe_offset + 4)
        require(1 <= count <= MAX_SECTIONS, "resource-limit", "Section count must be 1..96")
        require(2 <= opt_size <= 4096, "invalid-header", "Invalid optional-header size")
        opt = pe_offset + 24
        extent(opt, opt_size, self.r.size, "Optional header")
        magic, = self.r.unpack("<H", opt)
        require(magic in (0x10B, 0x20B), "unsupported-format", "Only PE32 and PE32+ images are supported")
        self.width = 8 if magic == 0x20B else 4
        expected_width = {0x14C: 4, 0x1C4: 4, 0x8664: 8, 0xAA64: 8, 0xA641: 8, 0xA64E: 8}.get(machine)
        require(expected_width in (None, self.width), "invalid-header", "Machine and optional-header pointer width disagree")
        self.pointer_format = "<Q" if self.width == 8 else "<I"
        fixed_size = 112 if self.width == 8 else 96
        require(opt_size >= fixed_size, "invalid-header", "Truncated fixed optional header")
        self.image_base, = self.r.unpack(self.pointer_format, opt + (24 if self.width == 8 else 28))
        entry, = self.r.unpack("<I", opt + 16)
        self.image_size, self.header_size = self.r.unpack("<II", opt + 56)
        subsystem, dll_flags = self.r.unpack("<HH", opt + 68)
        os_major, os_minor, _, _, sub_major, sub_minor = self.r.unpack("<HHHHHH", opt + 40)
        dirs, = self.r.unpack("<I", opt + fixed_size - 4)
        require(dirs <= MAX_DIRECTORIES, "resource-limit", "More than 16 data directories is unsupported")
        require(fixed_size + 8 * dirs <= opt_size, "invalid-header", "Directories exceed optional header")
        section_table = opt + opt_size
        table_end = extent(section_table, 40 * count, self.r.size, "Section table")
        require(table_end <= self.header_size <= self.r.size and self.header_size <= self.image_size,
                "invalid-header", "SizeOfHeaders does not contain the headers or exceeds image/file")
        extent(self.image_base, self.image_size, 1 << (8 * self.width), "Preferred image VA")
        for i in range(count):
            raw = self.r.read(section_table + 40 * i, 40)
            name = raw[:8].rstrip(b"\0").decode("ascii", "backslashreplace")
            vsize, va, rawsize, rawptr = struct.unpack_from("<IIII", raw, 8)
            flags, = struct.unpack_from("<I", raw, 36)
            mapped = max(vsize, rawsize)
            extent(va, mapped, self.image_size, "Section virtual range")
            require(not mapped or va >= self.header_size, "ambiguous-layout", "Section overlaps image headers")
            if rawsize:
                extent(rawptr, rawsize, self.r.size, "Section file range")
                require(rawptr >= self.header_size, "ambiguous-layout", "Section raw data overlaps headers")
            self.sections.append({"name": name, "virtualAddress": va, "virtualSize": vsize,
                                  "mappedSize": mapped, "rawOffset": rawptr, "rawSize": rawsize,
                                  "characteristics": flags, "executable": bool(flags & 0x20000000)})
        for start_key, size_key in (("virtualAddress", "mappedSize"), ("rawOffset", "rawSize")):
            ranges = sorted((s[start_key], s[start_key] + s[size_key]) for s in self.sections if s[size_key])
            require(all(a[1] <= b[0] for a, b in zip(ranges, ranges[1:])), "ambiguous-layout",
                    "Overlapping sections make address interpretation ambiguous")
        for i in range(dirs):
            address, size = self.r.unpack("<II", opt + fixed_size + 8 * i)
            # GlobalPtr is explicitly allowed a zero Size in Microsoft's PE format.
            require((address == 0) == (size == 0) or (i == 8 and address != 0),
                    "invalid-directory", "Data directory has an incomplete address/size pair")
            if address:
                if i == 4:  # The certificate directory uses a file offset, NOT an RVA.
                    extent(address, size, self.r.size, "Certificate file range")
                else:
                    self.raw_span(address, max(size, 1))
            self.directories.append((address, size))
        entry_section = self.virtual_region(entry) if entry else None
        entry_offset = self.raw_span(entry)[0] if entry else None
        self.header_result = {
            "format": "PE32+" if self.width == 8 else "PE32",
            "architecture": {"machine": machine, "name": MACHINES.get(machine, "unknown"),
                             "pointerBits": self.width * 8},
            "imageBase": self.image_base, "sizeOfImage": self.image_size,
            "coff": {"timestamp": timestamp, "characteristics": characteristics,
                     "isDLL": bool(characteristics & 0x2000), "sectionCount": count},
            "entryPoint": {"rva": entry, "va": self.image_base + entry if entry else None,
                           "fileOffset": entry_offset,
                           "executableSection": bool(entry_section and entry_section["executable"])},
            "subsystem": {"value": subsystem, "name": SUBSYSTEMS.get(subsystem, "unknown")},
            "declaredVersions": {"operatingSystem": [os_major, os_minor],
                                 "subsystem": [sub_major, sub_minor], "minimumOSVerified": False},
            "imageFeatures": {"aslr": bool(dll_flags & 0x40), "nxCompatible": bool(dll_flags & 0x100),
                              "controlFlowGuardDeclared": bool(dll_flags & 0x4000),
                              "exceptionDirectoryPresent": bool(self.directory(3)[0]),
                              "baseRelocationsPresent": bool(self.directory(5)[0]),
                              "clrDirectoryPresent": bool(self.directory(14)[0]),
                              "certificateDirectoryPresent": bool(self.directory(4)[0]),
                              "signatureVerified": False},
            "sections": self.sections,
            "dataDirectories": [{"name": DIRECTORY_NAMES[i], "address": a, "size": n,
                                 "addressKind": "file-offset" if i == 4 else "rva"}
                                for i, (a, n) in enumerate(self.directories) if a],
        }

    def thunks(self, rva, legacy_va=False):
        result = []
        ordinal_flag = 1 << (8 * self.width - 1)
        for index in range(MAX_SYMBOLS_PER_LIBRARY + 1):
            value, = self.rva_unpack(self.pointer_format, rva + index * self.width)
            if value == 0:
                return result
            require(index < MAX_SYMBOLS_PER_LIBRARY and self.symbol_count < MAX_SYMBOLS,
                    "resource-limit", "Import symbol count exceeds the bounded inventory")
            self.symbol_count += 1
            if value & ordinal_flag:
                require((value & ~(ordinal_flag | 0xFFFF)) == 0, "invalid-thunk", "Reserved ordinal bits are nonzero")
                result.append({"kind": "ordinal", "ordinal": value & 0xFFFF})
            else:
                if legacy_va:
                    name_rva = self.va_to_rva(value, 3)
                else:
                    require(value < 0x80000000, "invalid-thunk", "Import name RVA exceeds its 31-bit field")
                    name_rva = value
                hint, = self.rva_unpack("<H", name_rva)
                result.append({"kind": "name", "name": self.string(name_rva + 2), "hint": hint})
        raise PEError("unterminated-table", "Import lookup table has no terminator")

    def imports(self, delay=False):
        rva, size = self.directory(13 if delay else 1)
        if not rva:
            return []
        stride = 32 if delay else 20
        require(size >= stride, "invalid-directory", "Import directory is smaller than one descriptor")
        result = []
        for index in range(min(size // stride, MAX_LIBRARIES + 1)):
            values = self.rva_unpack("<8I" if delay else "<5I", rva + index * stride)
            if not any(values):
                return result
            self.library_count += 1
            require(self.library_count <= MAX_LIBRARIES, "resource-limit", "Too many import libraries")
            legacy = False
            if delay:
                attrs, name, handle, iat, lookup, bound, unload, timestamp = values
                require(attrs in (0, 1), "invalid-delay-attributes", "Unknown delay-import attribute bits")
                legacy = attrs == 0
                if legacy:
                    name, handle, iat, lookup, bound, unload = [self.va_to_rva(v) if v else 0
                                                               for v in (name, handle, iat, lookup, bound, unload)]
                require(lookup != 0, "unavailable-delay-lookup", "Delay import name table is absent")
                if handle:
                    self.virtual_region(handle, self.width)
                for optional_table in (bound, unload):
                    if optional_table:
                        self.raw_span(optional_table, self.width)
                source = "delay-name-table"
            else:
                lookup, timestamp, _forwarder, name, iat = values
                source = "import-lookup-table" if lookup else "unbound-iat"
            require(name != 0 and iat != 0, "invalid-import", "Import descriptor is missing name or IAT")
            dll = self.string(name)
            self.raw_span(iat, self.width)
            unavailable = not delay and not lookup and timestamp != 0
            symbols = None if unavailable else self.thunks(lookup or iat, legacy_va=legacy)
            if symbols is not None:
                self.raw_span(iat, (len(symbols) + 1) * self.width)
            else:
                self.warnings.append("bound-iat-without-lookup: " + dll)
            result.append({"dll": dll, "symbols": symbols,
                           "symbolStatus": "unavailable-bound-iat" if unavailable else "enumerated",
                           "lookupSource": "bound-iat" if unavailable else source,
                           "descriptorAddressKind": "va" if legacy else "rva",
                           "iatRva": iat, "timestamp": timestamp})
        raise PEError("unterminated-table", "Import descriptors have no terminator within their directory")

    def tls(self):
        rva, size = self.directory(9)
        if not rva:
            return {"present": False, "callbacks": []}
        expected = 40 if self.width == 8 else 24
        require(size >= expected, "invalid-tls", "TLS directory is truncated")
        start, end, index, callbacks, zero_fill, flags = self.rva_unpack("<QQQQII" if self.width == 8 else "<IIIIII", rva)
        require(end >= start and bool(start) == bool(end), "invalid-tls", "Invalid TLS template VA range")
        if start:
            template_rva = self.va_to_rva(start, end - start)
            if end != start:
                self.raw_span(template_rva, end - start)
        else:
            template_rva = None
        index_rva = self.va_to_rva(index, 4) if index else None
        require(index_rva is not None, "invalid-tls", "TLS index storage VA is absent")
        result = []
        if callbacks:
            array_rva = self.va_to_rva(callbacks, self.width)
            for i in range(MAX_CALLBACKS + 1):
                value, = self.rva_unpack(self.pointer_format, array_rva + i * self.width)
                if value == 0:
                    break
                require(i < MAX_CALLBACKS, "resource-limit", "Too many TLS callbacks")
                callback_rva = self.va_to_rva(value)
                section = self.virtual_region(callback_rva)
                offset, _ = self.raw_span(callback_rva)
                result.append({"va": value, "rva": callback_rva, "fileOffset": offset,
                               "executableSection": bool(section and section["executable"])})
        return {"present": True, "templateRva": template_rva, "templateBytes": end - start,
                "indexRva": index_rva, "zeroFillBytes": zero_fill,
                "characteristics": flags, "callbacks": result, "callbacksExecuted": False}

    def inspect(self):
        self.headers()
        imports, delayed, tls = self.imports(), self.imports(delay=True), self.tls()
        hints = []
        for table, libraries in (("import", imports), ("delay-import", delayed)):
            for lib in libraries:
                tokens = [("dll", lib["dll"])] + [("symbol", s["name"]) for s in lib["symbols"] or [] if s["kind"] == "name"]
                for kind, token in tokens:
                    lower = token.lower()
                    families = []
                    if lower in ("d3d12.dll", "d3d12core.dll") or lower.startswith("d3d12"):
                        families.append("Direct3D 12")
                    if lower == "dxgi.dll" or lower.startswith("createdxgifactory"):
                        families.append("DXGI")
                    if "nvngx" in lower or lower.startswith("nvsdk_ngx_"):
                        families.append("NVIDIA NGX")
                    if re.search(r"(?:fidelityfx|ffx_|(?:^|[_\-.])fsr[234]?(?:[_\-.]|$))", lower):
                        families.append("AMD FidelityFX/FSR")
                    hints.extend({"family": family, "table": table, "dll": lib["dll"],
                                  "evidenceKind": kind, "evidence": token, "supportDetermined": False}
                                 for family in families)
        self.header_result.update({"imports": imports, "delayImports": delayed, "tls": tls,
                                   "graphicsHints": hints, "warnings": self.warnings,
                                   "inventory": {"libraries": self.library_count, "symbols": self.symbol_count},
                                   "limitations": LIMITATIONS, "executionPerformed": False,
                                   "wineUsed": False, "supportDetermined": False})
        return self.header_result


def inspect_file(path):
    """Inspect exactly one explicitly selected regular .exe/.dll; never follow its dependencies."""
    selected = os.fspath(path)
    require(isinstance(selected, str) and "\0" not in selected, "invalid-path", "Select a text path without NUL bytes")
    require(Path(selected).suffix.lower() in (".exe", ".dll"), "unsupported-extension", "Select an .exe or .dll file explicitly")
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(selected, flags)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode), "not-regular-file", "Selected path is not a regular file")
        require(64 <= before.st_size <= MAX_FILE_BYTES, "file-size-limit", "File size must be 64 bytes..256 MiB")
        reader = Reader(fd, before.st_size)
        result = PEImage(reader).inspect()
        digest = reader.sha256()
        require(fingerprint(before) == fingerprint(os.fstat(fd)), "file-changed", "File metadata changed during inspection")
        return {"input": selected, "status": "ok", "size": before.st_size, "sha256": digest, **result}
    finally:
        os.close(fd)


def inspect_paths(paths):
    require(0 < len(paths) <= MAX_FILES, "file-count-limit", "Select 1..32 explicit files")
    results = []
    output_bytes = 0
    for path in paths:
        try:
            result = inspect_file(path)
            output_bytes += len(json.dumps(result, ensure_ascii=True))
            require(output_bytes <= MAX_JSON_BYTES - 64 * 1024, "resource-limit", "Batch JSON exceeds the 16 MiB compact-output budget")
            results.append(result)
        except (PEError, OSError) as error:
            results.append({"input": os.fspath(path), "status": "error", "executionPerformed": False,
                            "wineUsed": False, "supportDetermined": False,
                            "error": {"code": error.code if isinstance(error, PEError) else "file-access",
                                      "message": str(error) if isinstance(error, PEError) else "Cannot open or read the selected regular file"}})
    return {"schemaVersion": 1, "kind": "playmelt-pe-inspection", "executionPerformed": False,
            "wineUsed": False, "supportDetermined": False, "files": results}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pretty", action="store_true", help="Indent JSON output")
    parser.add_argument("files", nargs="+", metavar="FILE", help="Explicit .exe/.dll path (no recursive scan)")
    args = parser.parse_args(argv)
    if len(args.files) > MAX_FILES:
        parser.error("at most 32 files per invocation")
    result = inspect_paths(args.files)
    json.dump(result, sys.stdout, ensure_ascii=True, indent=2 if args.pretty else None, allow_nan=False)
    sys.stdout.write("\n")
    return 1 if any(item["status"] == "error" for item in result["files"]) else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(1)
