#!/usr/bin/env python3
"""Read-only AMD64 unwind metadata decoder; never dispatches or unwinds code.

Microsoft contracts:
https://learn.microsoft.com/en-us/cpp/build/exception-handling-x64
https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
Version 1 only. Unknown encodings fail explicitly; handler data stays opaque.
"""
import argparse
import json
import os
from pathlib import Path
import stat

from pe_inspect import PEError, PEImage, Reader, require, fingerprint, MAX_FILE_BYTES

MAX_FUNCTIONS = 8192
MAX_UNWIND_RECORDS = 8192
MAX_OPERATIONS = 65536
MAX_CHAIN_DEPTH = 32
MAX_OUTPUT_BYTES = 16 * 1024 * 1024
OP_NAMES = {0: "PUSH_NONVOL", 1: "ALLOC_LARGE", 2: "ALLOC_SMALL", 3: "SET_FPREG",
            4: "SAVE_NONVOL", 5: "SAVE_NONVOL_FAR", 8: "SAVE_XMM128",
            9: "SAVE_XMM128_FAR", 10: "PUSH_MACHFRAME"}
NONVOLATILE_GPRS = {3, 5, 6, 7, 12, 13, 14, 15}


def decode_unwind(image):
    """image.headers() must already have run; offsets are image-relative."""
    require(image.header_result["architecture"]["machine"] == 0x8664 and image.width == 8,
            "unsupported-architecture", "Unwind decoder supports AMD64 PE32+ only")
    directory, size = image.directory(3)
    result = {"present": bool(directory), "functions": [], "records": [],
              "metadataDecoded": True, "unwindExecuted": False,
              "exceptionDispatchImplemented": False, "machineCodeValidated": False,
              "handlerDataDecoded": False, "versionsSupported": [1], "operationCount": 0,
              "dynamicFunctionTablesInspected": False}
    if not directory:
        return result
    require(directory % 4 == 0 and size % 12 == 0 and 0 < size // 12 <= MAX_FUNCTIONS,
            "invalid-unwind-table", "Exception table must contain bounded aligned RUNTIME_FUNCTION entries")

    def function_at(rva):
        begin, end, unwind = image.rva_unpack("<III", rva)
        require(begin < end and unwind != 0 and unwind % 4 == 0,
                "invalid-runtime-function", "Function range or aligned unwind RVA is invalid")
        section = image.virtual_region(begin, end - begin)
        require(section is not None and section["executable"],
                "invalid-runtime-function", "Function range must lie in one executable section")
        image.raw_span(begin, end - begin)
        return {"beginRva": begin, "endRva": end, "unwindRva": unwind}

    pending = []
    previous = -1
    for offset in range(0, size, 12):
        function = function_at(directory + offset)
        require(function["beginRva"] > previous, "invalid-unwind-table",
                "Function table entries must have increasing start addresses")
        previous = function["beginRva"]
        result["functions"].append(function)
        pending.append(function["unwindRva"])

    records = {}
    total_operations = 0
    while pending:
        rva = pending.pop()
        if rva in records:
            continue
        require(len(records) < MAX_UNWIND_RECORDS, "resource-limit", "Too many unwind records")
        first, prolog, count, frame = image.rva_unpack("<BBBB", rva)
        version, flags = first & 7, first >> 3
        require(version == 1, "unsupported-unwind-version", "Only unwind version 1 is decoded")
        require(flags & ~7 == 0 and not (flags & 4 and flags & 3),
                "invalid-unwind-flags", "Unknown or conflicting unwind flags")
        require(frame & 15 != 0 or frame >> 4 == 0,
                "invalid-unwind-frame", "Frame offset requires a frame register")
        require(frame & 15 == 0 or frame & 15 in NONVOLATILE_GPRS,
                "unsupported-unwind-register", "Frame register must be a supported nonvolatile GPR")
        # Include the padding slot in the bounds check, even when it is unused.
        padded = (count + 1) & ~1
        image.raw_span(rva, 4 + padded * 2)
        operations, cursor, last_offset = [], 0, prolog
        while cursor < count:
            code_offset, encoded = image.rva_unpack("<BB", rva + 4 + cursor * 2)
            opcode, info = encoded & 15, encoded >> 4
            require(opcode in OP_NAMES, "unsupported-unwind-opcode", "Unwind opcode is not supported in version 1")
            if opcode in (0, 4, 5):
                require(info in NONVOLATILE_GPRS, "unsupported-unwind-register", "Operation requires a supported nonvolatile GPR")
            elif opcode in (8, 9):
                require(info >= 6, "unsupported-unwind-register", "Operation requires a nonvolatile XMM register")
            if flags & 4:
                require(opcode == 4, "unsupported-unwind-chain-operation", "Secondary chain operations are limited to SAVE_NONVOL")
            require(code_offset <= last_offset, "invalid-unwind-order", "Code offsets must descend within the prolog")
            last_offset = code_offset
            slots = 1
            if opcode == 1:
                require(info in (0, 1), "invalid-unwind-opinfo", "ALLOC_LARGE has only two encodings")
                slots = 2 if info == 0 else 3
            elif opcode in (4, 8):
                slots = 2
            elif opcode in (5, 9):
                slots = 3
            elif opcode == 3:
                require(info == 0 and frame & 15 != 0, "invalid-unwind-opinfo", "SET_FPREG requires the declared frame register")
            elif opcode == 10:
                require(info in (0, 1), "invalid-unwind-opinfo", "PUSH_MACHFRAME has only two encodings")
            require(cursor + slots <= count, "truncated-unwind-operation", "Operand slots exceed CountOfCodes")
            operation = {"codeOffset": code_offset, "opcode": OP_NAMES[opcode], "opInfo": info, "slots": slots}
            if slots > 1:
                operand, = image.rva_unpack("<H" if slots == 2 else "<I", rva + 6 + cursor * 2)
                scale = 8 if (opcode == 1 and info == 0) or opcode == 4 else 16 if opcode == 8 else 1
                operation["operandBytes"] = operand * scale
                alignment = 16 if opcode in (8, 9) else 8
                require(operation["operandBytes"] % alignment == 0 and (opcode != 1 or operand > 0),
                        "invalid-unwind-operand", "Operand alignment or nonzero allocation is invalid")
            elif opcode == 2:
                operation["operandBytes"] = info * 8 + 8
            operations.append(operation)
            total_operations += 1
            require(total_operations <= MAX_OPERATIONS, "resource-limit", "Unwind operation budget exceeded")
            cursor += slots
        record = {"rva": rva, "version": version, "flags": flags, "prologBytes": prolog,
                  "slotCount": count, "frameRegister": frame & 15, "frameOffsetBytes": (frame >> 4) * 16,
                  "operations": operations}
        trailer = rva + 4 + padded * 2
        if flags & 4:
            record["chainedFunction"] = function_at(trailer)
            pending.append(record["chainedFunction"]["unwindRva"])
        elif flags & 3:
            handler, = image.rva_unpack("<I", trailer)
            section = image.virtual_region(handler)
            require(handler != 0 and section is not None and section["executable"],
                    "invalid-unwind-handler", "Handler RVA must be in executable file-backed data")
            image.raw_span(handler)
            record["handlerRva"] = handler
            record["opaqueHandlerDataRva"] = trailer + 4
        records[rva] = record

    for function in result["functions"]:
        record = records[function["unwindRva"]]
        require(record["prologBytes"] <= function["endRva"] - function["beginRva"],
                "invalid-unwind-prolog", "Prolog exceeds function extent")
    for rva, record in records.items():
        seen, current = set(), record
        while True:
            require(current["rva"] not in seen, "unwind-chain-cycle", "Unwind chain contains a cycle")
            seen.add(current["rva"])
            require(len(seen) <= MAX_CHAIN_DEPTH, "resource-limit", "Unwind chain is too deep")
            if "chainedFunction" not in current:
                break
            function = current["chainedFunction"]
            parent = records[function["unwindRva"]]
            require(parent["prologBytes"] <= function["endRva"] - function["beginRva"],
                    "invalid-unwind-prolog", "Chained prolog exceeds function extent")
            require((current["frameRegister"], current["frameOffsetBytes"]) ==
                    (parent["frameRegister"], parent["frameOffsetBytes"]),
                    "invalid-unwind-chain", "Chained frame declarations disagree")
            current = parent
    result["records"] = [records[key] for key in sorted(records)]
    result["operationCount"] = total_operations
    return result


def inspect_unwind_file(path, *, serialized=False):
    selected = os.fspath(path)
    require(isinstance(selected, str) and "\0" not in selected and Path(selected).suffix.lower() in (".dll", ".exe"),
            "invalid-path", "Select one explicit .dll or .exe")
    fd = os.open(selected, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and 64 <= before.st_size <= MAX_FILE_BYTES,
                "invalid-file", "Selected image must be a bounded regular file")
        reader = Reader(fd, before.st_size)
        image = PEImage(reader)
        image.headers()
        metadata = decode_unwind(image)
        digest = reader.sha256()
        require(fingerprint(before) == fingerprint(os.fstat(fd)), "file-changed", "Image changed while reading metadata")
        result = {"input": selected, "sha256": digest, "status": "decoded", "unwind": metadata,
                  "executionPerformed": False, "supportDetermined": False}
        encoded = json.dumps(result, indent=2)
        require(len(encoded.encode()) + 1 <= MAX_OUTPUT_BYTES, "resource-limit", "Decoded JSON is too large")
        return encoded if serialized else result
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file")
    args = parser.parse_args()
    try:
        result = inspect_unwind_file(args.file, serialized=True)
    except (PEError, OSError) as error:
        print(json.dumps({"status": "error", "code": getattr(error, "code", "read-error"),
                          "message": str(error), "executionPerformed": False, "supportDetermined": False}))
        return 1
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
