"""CPU-only synthetic PE fixtures. No Windows code is executed or resolved."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import random
import struct
import tempfile
import types
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("pe_inspect", HERE / "pe_inspect.py")
pe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pe)


class Fixture:
    """Build an inert ~10 KiB PE image entirely from structs and ASCII names."""
    def __init__(self, bits=64, imports=True, delay=True, tls=True, legacy=False):
        self.bits = bits
        self.width = bits // 8
        self.ptr = "<Q" if bits == 64 else "<I"
        self.base = 0x140000000 if bits == 64 else 0x400000
        self.data = bytearray(0x2600)
        self.opt = 0x98
        self.opt_size = 240 if bits == 64 else 224
        self.dirs = self.opt + (112 if bits == 64 else 96)
        self.sections = self.opt + self.opt_size
        self.put(0, b"MZ")
        self.pack(0x3C, "<I", 0x80)
        self.put(0x80, b"PE\0\0")
        self.pack(0x84, "<HHIIIHH", 0x8664 if bits == 64 else 0x14C, 2, 123, 0, 0, self.opt_size, 0x2022)
        self.pack(self.opt, "<H", 0x20B if bits == 64 else 0x10B)
        self.pack(self.opt + 16, "<I", 0x1000)
        self.pack(self.opt + (24 if bits == 64 else 28), self.ptr, self.base)
        self.pack(self.opt + 32, "<II", 0x1000, 0x200)
        self.pack(self.opt + 40, "<HHHHHH", 6, 0, 0, 0, 6, 0)
        self.pack(self.opt + 56, "<II", 0x5000, 0x400)
        self.pack(self.opt + 68, "<HH", 2, 0x4140)
        self.pack(self.dirs - 4, "<I", 16)
        self.section(0, b".text", 0x200, 0x1000, 0x200, 0x400, 0x60000020)
        self.section(1, b".rdata", 0x2400, 0x2000, 0x2000, 0x600, 0x40000040)
        # Deliberately inert text bytes: the inspector must not execute anything.
        self.put(0x400, b"NOT EXECUTABLE CODE")
        if imports:
            self.directory(1, 0x2100, 40)
            self.rpack(0x2100, "<5I", 0x2300, 0, 0, 0x2200, 0x2400)
            self.rput(0x2200, b"d3d12.dll\0")
            self.rpack(0x2300, self.ptr, 0x2500)
            self.rpack(0x2300 + self.width, self.ptr, (1 << (bits - 1)) | 7)
            self.rpack(0x2500, "<H", 19)
            self.rput(0x2502, b"D3D12CreateDevice\0")
        if delay:
            self.directory(13, 0x2600, 64)
            conv = lambda rva: self.base + rva if legacy else rva
            self.rpack(0x2600, "<8I", 0 if legacy else 1, conv(0x2700), conv(0x2B00),
                       conv(0x2900), conv(0x2800), 0, 0, 0)
            self.rput(0x2700, b"nvngx_dlss.dll\0")
            self.rpack(0x2800, self.ptr, conv(0x2A00))
            self.rpack(0x2A00, "<H", 0)
            self.rput(0x2A02, b"NVSDK_NGX_D3D12_Init\0")
        if tls:
            self.directory(9, 0x2C00, 40 if bits == 64 else 24)
            self.rpack(0x2C00, "<QQQQII" if bits == 64 else "<IIIIII",
                       self.base + 0x2E00, self.base + 0x2E04, self.base + 0x2F00,
                       self.base + 0x2D00, 16, 0)
            self.rpack(0x2D00, self.ptr, self.base + 0x1000)
            self.rput(0x2E00, b"DATA")

    def put(self, offset, data):
        self.data[offset:offset + len(data)] = data

    def pack(self, offset, fmt, *values):
        struct.pack_into(fmt, self.data, offset, *values)

    def roffset(self, rva):
        return rva - 0x2000 + 0x600 if rva >= 0x2000 else rva - 0x1000 + 0x400

    def rput(self, rva, data):
        self.put(self.roffset(rva), data)

    def rpack(self, rva, fmt, *values):
        self.pack(self.roffset(rva), fmt, *values)

    def directory(self, number, address, size):
        self.pack(self.dirs + number * 8, "<II", address, size)

    def section(self, index, name, vsize, va, rawsize, rawptr, flags):
        off = self.sections + 40 * index
        self.put(off, name.ljust(8, b"\0"))
        self.pack(off + 8, "<IIII", vsize, va, rawsize, rawptr)
        self.pack(off + 36, "<I", flags)


class PETests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="playmelt-pe-fixtures-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def save(self, fixture=None, name="fixture.exe"):
        path = self.root / name
        path.write_bytes((fixture or Fixture()).data)
        return path

    def inspect(self, fixture=None):
        return pe.inspect_file(self.save(fixture))

    def reject(self, fixture, code=None):
        with self.assertRaises(pe.PEError) as caught:
            self.inspect(fixture)
        if code:
            self.assertEqual(caught.exception.code, code)

    def test_pe64_named_ordinal_delayed_tls(self):
        f = Fixture()
        r = self.inspect(f)
        self.assertEqual(r["sha256"], hashlib.sha256(f.data).hexdigest())
        self.assertEqual(r["architecture"]["name"], "x86_64")
        self.assertEqual(r["entryPoint"]["fileOffset"], 0x400)
        self.assertEqual(r["imports"][0]["symbols"], [
            {"kind": "name", "name": "D3D12CreateDevice", "hint": 19}, {"kind": "ordinal", "ordinal": 7}])
        self.assertEqual(r["delayImports"][0]["symbols"][0]["name"], "NVSDK_NGX_D3D12_Init")
        self.assertEqual(r["tls"]["callbacks"][0]["rva"], 0x1000)
        self.assertFalse(r["tls"]["callbacksExecuted"])
        self.assertFalse(r["supportDetermined"])
        self.assertFalse(r["executionPerformed"])
        self.assertFalse(r["wineUsed"])
        self.assertTrue(r["imageFeatures"]["controlFlowGuardDeclared"])

    def test_pe32(self):
        r = self.inspect(Fixture(bits=32))
        self.assertEqual(r["format"], "PE32")
        self.assertEqual(r["tls"]["templateBytes"], 4)
        self.assertEqual(r["architecture"]["pointerBits"], 32)

    def test_legacy_delay_va32(self):
        r = self.inspect(Fixture(bits=32, legacy=True))
        self.assertEqual(r["delayImports"][0]["descriptorAddressKind"], "va")
        self.assertEqual(r["delayImports"][0]["symbols"][0]["kind"], "name")

    def test_arm64_not_a_compatibility_verdict(self):
        f = Fixture()
        f.pack(0x84, "<H", 0xAA64)
        r = self.inspect(f)
        self.assertEqual(r["architecture"]["name"], "arm64")
        self.assertFalse(r["supportDetermined"])

    def test_machine_pointer_width_mismatch(self):
        f = Fixture()
        f.pack(0x84, "<H", 0x14C)
        self.reject(f, "invalid-header")

    def test_unknown_machine_preserved_without_support_claim(self):
        f = Fixture()
        f.pack(0x84, "<H", 0xFFFF)
        r = self.inspect(f)
        self.assertEqual(r["architecture"]["name"], "unknown")
        self.assertEqual(r["architecture"]["machine"], 0xFFFF)
        self.assertFalse(r["supportDetermined"])

    def test_no_tables_and_null_entry(self):
        f = Fixture(imports=False, delay=False, tls=False)
        f.pack(f.opt + 16, "<I", 0)
        r = self.inspect(f)
        self.assertEqual(r["imports"], [])
        self.assertIsNone(r["entryPoint"]["va"])
        self.assertFalse(r["tls"]["present"])

    def test_unbound_iat_fallback(self):
        f = Fixture()
        f.rpack(0x2100, "<I", 0)
        f.rpack(0x2400, "<Q", 0x2500)
        self.assertEqual(self.inspect(f)["imports"][0]["lookupSource"], "unbound-iat")

    def test_bound_iat_does_not_treat_addresses_as_names(self):
        f = Fixture()
        f.rpack(0x2100, "<II", 0, 1)
        f.rpack(0x2400, "<Q", 0x7FFFAABBCCDD)
        r = self.inspect(f)
        self.assertIsNone(r["imports"][0]["symbols"])
        self.assertEqual(r["imports"][0]["symbolStatus"], "unavailable-bound-iat")

    def test_graphics_hints_not_features(self):
        f = Fixture()
        f.rput(0x2700, b"amd_fidelityfx_dx12.dll\0")
        r = self.inspect(f)
        families = {h["family"] for h in r["graphicsHints"]}
        self.assertEqual(families, {"Direct3D 12", "NVIDIA NGX", "AMD FidelityFX/FSR"})
        self.assertTrue(all(not h["supportDetermined"] for h in r["graphicsHints"]))
        self.assertNotIn("DLSS 5", json.dumps(r))

    def test_dynamic_import_limits_are_disclosed(self):
        f = Fixture()
        f.rput(0x2200, b"KERNEL32.dll\0")
        f.rput(0x2502, b"LoadLibraryW\0")
        r = self.inspect(f)
        self.assertIn("LoadLibrary/GetProcAddress", " ".join(r["limitations"]))

    def test_certificate_uses_file_offset(self):
        f = Fixture()
        f.directory(4, 0x2500, 32)
        cert = [d for d in self.inspect(f)["dataDirectories"] if d["name"] == "certificate"][0]
        self.assertEqual(cert["addressKind"], "file-offset")

    def test_global_pointer_zero_size(self):
        f = Fixture()
        f.directory(8, 0x3000, 0)
        self.inspect(f)

    def test_zero_fill_tls_index_storage(self):
        f = Fixture()
        f.rpack(0x2C00 + 16, "<Q", f.base + 0x4100)
        self.assertEqual(self.inspect(f)["tls"]["indexRva"], 0x4100)

    def test_signatures(self):
        for offset in (0, 0x80):
            with self.subTest(offset=offset):
                f = Fixture()
                f.put(offset, b"NO")
                self.reject(f, "not-pe")

    def test_truncated_inputs(self):
        for length in (0, 63, 64, 128, 256, 0x500, 0x1000):
            with self.subTest(length=length):
                f = Fixture()
                del f.data[length:]
                self.reject(f)

    def test_invalid_header_counts(self):
        for offset, fmt, value in ((0x3C, "<I", 0xFFFFFFFF), (0x86, "<H", 97),
                                   (0x94, "<H", 2), (Fixture().dirs - 4, "<I", 17)):
            with self.subTest(offset=offset):
                f = Fixture()
                f.pack(offset, fmt, value)
                self.reject(f)

    def test_optional_directory_overrun(self):
        f = Fixture()
        f.pack(0x94, "<H", 112)
        self.reject(f, "invalid-header")

    def test_wrong_optional_magic(self):
        f = Fixture()
        f.pack(f.opt, "<H", 0x107)
        self.reject(f, "unsupported-format")

    def test_section_virtual_overflow(self):
        f = Fixture()
        f.pack(f.sections + 12, "<I", 0xFFFFFFF0)
        self.reject(f, "out-of-bounds")

    def test_raw_overlap(self):
        f = Fixture()
        f.pack(f.sections + 40 + 20, "<I", 0x400)
        self.reject(f, "ambiguous-layout")

    def test_virtual_overlap(self):
        f = Fixture()
        f.pack(f.sections + 40 + 12, "<I", 0x1100)
        self.reject(f, "ambiguous-layout")

    def test_raw_header_overlap(self):
        f = Fixture()
        f.pack(f.sections + 20, "<I", 0x200)
        self.reject(f, "ambiguous-layout")

    def test_header_size_does_not_cover_section_table(self):
        f = Fixture()
        f.pack(f.opt + 60, "<I", 0x100)
        self.reject(f, "invalid-header")

    def test_directory_outside_file(self):
        f = Fixture()
        f.directory(1, 0x2100, 0xFFFFFF00)
        self.reject(f, "out-of-bounds")

    def test_incomplete_directory_pair(self):
        f = Fixture()
        f.directory(1, 0, 40)
        self.reject(f, "invalid-directory")

    def test_unbacked_name(self):
        f = Fixture()
        f.rpack(0x2100 + 12, "<I", 0x4100)
        self.reject(f, "unbacked-rva")

    def test_unmapped_name(self):
        f = Fixture()
        f.rpack(0x2100 + 12, "<I", 0x1800)
        self.reject(f, "unmapped-rva")

    def test_ordinal_reserved_bits(self):
        f = Fixture()
        f.rpack(0x2300, "<Q", (1 << 63) | (1 << 20) | 7)
        self.reject(f, "invalid-thunk")

    def test_name_thunk_high_bits(self):
        f = Fixture()
        f.rpack(0x2300, "<Q", 0x100002500)
        self.reject(f, "invalid-thunk")

    def test_non_ascii_name(self):
        f = Fixture()
        f.rput(0x2200, b"bad\xff.dll\0")
        self.reject(f, "invalid-string")

    def test_unterminated_string(self):
        f = Fixture()
        f.rpack(0x2100 + 12, "<I", 0x3FF0)
        f.rput(0x3FF0, b"X" * 16)
        self.reject(f, "invalid-string")

    def test_descriptor_requires_null_terminator(self):
        f = Fixture()
        f.directory(1, 0x2100, 20)
        self.reject(f, "unterminated-table")

    def test_repeated_pointer_does_not_recurse(self):
        f = Fixture()
        # An adversarial name pointer targeting its own thunk still has bounded reads.
        f.rpack(0x2300, "<Q", 0x2300)
        self.reject(f, "invalid-string")

    def test_symbol_limit(self):
        with patch.object(pe, "MAX_SYMBOLS_PER_LIBRARY", 1):
            self.reject(Fixture(), "resource-limit")

    def test_total_symbol_limit(self):
        with patch.object(pe, "MAX_SYMBOLS", 2):
            self.reject(Fixture(), "resource-limit")

    def test_library_limit(self):
        with patch.object(pe, "MAX_LIBRARIES", 1):
            self.reject(Fixture(), "resource-limit")

    def test_text_budget(self):
        with patch.object(pe, "MAX_IMPORT_TEXT_BYTES", 4):
            self.reject(Fixture(), "resource-limit")

    def test_metadata_budget(self):
        with patch.object(pe, "MAX_METADATA_READ", 512):
            self.reject(Fixture(), "resource-limit")

    def test_delay_reserved_bits(self):
        f = Fixture()
        f.rpack(0x2600, "<I", 3)
        self.reject(f, "invalid-delay-attributes")

    def test_delay_missing_lookup(self):
        f = Fixture()
        f.rpack(0x2600 + 16, "<I", 0)
        self.reject(f, "unavailable-delay-lookup")

    def test_delay_bad_legacy_va(self):
        f = Fixture(bits=32, legacy=True)
        f.rpack(0x2600 + 4, "<I", f.base - 1)
        self.reject(f, "invalid-va")

    def test_delay_table_termination(self):
        f = Fixture()
        f.directory(13, 0x2600, 32)
        self.reject(f, "unterminated-table")

    def test_tls_truncated(self):
        f = Fixture()
        f.directory(9, 0x2C00, 39)
        self.reject(f, "invalid-tls")

    def test_tls_bad_range(self):
        f = Fixture()
        f.rpack(0x2C00 + 8, "<Q", f.base + 0x2000)
        self.reject(f, "invalid-tls")

    def test_tls_callback_outside_image(self):
        f = Fixture()
        f.rpack(0x2D00, "<Q", f.base + 0x9000)
        self.reject(f, "out-of-bounds")

    def test_tls_callback_limit(self):
        with patch.object(pe, "MAX_CALLBACKS", 0):
            self.reject(Fixture(), "resource-limit")

    def test_tls_zero_callbacks(self):
        f = Fixture()
        f.rpack(0x2C00 + 24, "<Q", 0)
        self.assertEqual(self.inspect(f)["tls"]["callbacks"], [])

    def test_clr_presence_is_not_managed_runtime_support(self):
        f = Fixture()
        f.directory(14, 0x3000, 72)
        r = self.inspect(f)
        self.assertTrue(r["imageFeatures"]["clrDirectoryPresent"])
        self.assertFalse(r["supportDetermined"])

    def test_file_size_limit_before_read(self):
        path = self.save()
        with patch.object(pe, "MAX_FILE_BYTES", 100), patch.object(pe.os, "pread") as read:
            with self.assertRaises(pe.PEError):
                pe.inspect_file(path)
            read.assert_not_called()

    def test_symlink_rejected(self):
        original = self.save()
        link = self.root / "link.exe"
        link.symlink_to(original)
        result = pe.inspect_paths([link])
        self.assertEqual(result["files"][0]["status"], "error")

    def test_fifo_rejected_without_blocking(self):
        path = self.root / "pipe.exe"
        os.mkfifo(path)
        result = pe.inspect_paths([path])
        self.assertEqual(result["files"][0]["error"]["code"], "not-regular-file")

    def test_directory_and_extension_rejected(self):
        directory = self.root / "directory.exe"
        directory.mkdir()
        result = pe.inspect_paths([directory, self.root / "file.txt"])
        self.assertTrue(all(f["status"] == "error" for f in result["files"]))

    def test_missing_file_error_no_traceback(self):
        result = pe.inspect_paths([self.root / "missing.exe"])
        self.assertEqual(result["files"][0]["error"]["code"], "file-access")

    def test_nul_path_clean_error(self):
        result = pe.inspect_paths(["file\0.exe"])
        self.assertEqual(result["files"][0]["error"]["code"], "invalid-path")

    def test_open_fd_always_closed_on_parser_error(self):
        f = Fixture()
        f.put(0, b"NO")
        real_close = pe.os.close
        closed = []
        def close(fd):
            closed.append(fd)
            real_close(fd)
        with patch.object(pe.os, "close", side_effect=close):
            self.reject(f)
        self.assertEqual(len(closed), 1)
        with self.assertRaises(OSError):
            os.fstat(closed[0])

    def test_file_change_detected(self):
        path = self.save()
        info = path.stat()
        changed = types.SimpleNamespace(st_dev=info.st_dev, st_ino=info.st_ino,
                                        st_size=info.st_size, st_mtime_ns=info.st_mtime_ns + 1,
                                        st_ctime_ns=info.st_ctime_ns)
        with patch.object(pe.os, "fstat", side_effect=[info, changed]):
            with self.assertRaises(pe.PEError) as caught:
                pe.inspect_file(path)
        self.assertEqual(caught.exception.code, "file-changed")

    def test_bounded_reads_and_streaming_hash(self):
        path = self.save()
        actual = pe.os.pread
        sizes = []
        def read(fd, size, offset):
            sizes.append(size)
            return actual(fd, size, offset)
        with patch.object(pe.os, "pread", side_effect=read):
            pe.inspect_file(path)
        self.assertLessEqual(max(sizes), pe.HASH_CHUNK)

    def test_batch_output_budget(self):
        with patch.object(pe, "MAX_JSON_BYTES", 65537):
            result = pe.inspect_paths([self.save()])
        self.assertEqual(result["files"][0]["error"]["code"], "resource-limit")

    def test_batch_file_limit(self):
        with self.assertRaises(pe.PEError):
            pe.inspect_paths(["none.exe"] * 33)

    def test_cli_contract_and_exit_codes(self):
        valid = self.save()
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream):
            code = pe.main(["--pretty", str(valid), str(self.root / "missing.dll")])
        result = json.loads(stream.getvalue())
        self.assertEqual(code, 1)
        self.assertEqual(result["schemaVersion"], 1)
        self.assertEqual(result["kind"], "playmelt-pe-inspection")
        self.assertFalse(result["executionPerformed"])
        self.assertEqual([f["status"] for f in result["files"]], ["ok", "error"])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(pe.main([str(valid)]), 0)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
            pe.main([])
        self.assertEqual(caught.exception.code, 2)

    def test_seeded_small_mutations_fail_cleanly(self):
        rng = random.Random(7331)
        for _ in range(128):
            f = Fixture()
            for _ in range(rng.randrange(1, 5)):
                f.data[rng.randrange(len(f.data))] = rng.randrange(256)
            try:
                self.inspect(f)
            except pe.PEError:
                pass  # No struct.error, IndexError, infinite traversal or execution.


if __name__ == "__main__":
    unittest.main()
