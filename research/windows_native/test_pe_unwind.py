"""Inert PE fixtures only. No DLL, handler, instruction or guest stack is run."""
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

import pe_unwind as uw
from test_pe_inspect import Fixture


class UnwindTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        products = Path(__file__).resolve().parents[2] / "Products.noindex"
        products.mkdir(exist_ok=True)
        cls.scratch = tempfile.TemporaryDirectory(prefix="unwind-metadata-tests-", dir=products)
        cls.path = Path(cls.scratch.name) / "fixture.dll"

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def fixture(self, count=1):
        f = Fixture(imports=False, delay=False, tls=False)
        f.directory(3, 0x2100, count * 12)
        for i in range(count):
            f.rpack(0x2100 + 12 * i, "<III", 0x1000 + i * 0x40, 0x1040 + i * 0x40, 0x2200 + i * 0x40)
            f.rput(0x2200 + i * 0x40, bytes([1, 8, 2, 0, 8, 0x32, 1, 0x30]))
        return f

    def inspect(self, f):
        self.path.write_bytes(f.data)
        return uw.inspect_unwind_file(self.path)

    def rejects(self, f, code):
        with self.assertRaises(uw.PEError) as caught:
            self.inspect(f)
        self.assertEqual(code, caught.exception.code)

    def test_small_allocation_and_push(self):
        result = self.inspect(self.fixture())
        record = result["unwind"]["records"][0]
        self.assertEqual(["ALLOC_SMALL", "PUSH_NONVOL"], [x["opcode"] for x in record["operations"]])
        self.assertEqual(32, record["operations"][0]["operandBytes"])
        self.assertEqual(3, record["operations"][1]["opInfo"])
        self.assertFalse(result["executionPerformed"])
        self.assertFalse(result["supportDetermined"])
        self.assertFalse(result["unwind"]["exceptionDispatchImplemented"])

    def test_large_allocation_operand_slots_not_operations(self):
        for info, operand, expected in [(0, b"\x20\x00", 256), (1, b"\x00\x00\x08\x00", 524288)]:
            with self.subTest(info=info):
                f = self.fixture(); count = 1 + len(operand) // 2
                f.rput(0x2200, bytes([1, 8, count, 0, 8, (info << 4) | 1]) + operand)
                record = self.inspect(f)["unwind"]["records"][0]
                self.assertEqual(1, len(record["operations"]))
                self.assertEqual(expected, record["operations"][0]["operandBytes"])

    def test_save_offsets_and_scaling(self):
        for opcode, operand, expected in [(4, b"\x04\x00", 32), (5, b"\x80\x00\x00\x00", 128),
                                          (8, b"\x04\x00", 64), (9, b"\x80\x00\x00\x00", 128)]:
            with self.subTest(opcode=opcode):
                f = self.fixture(); count = 1 + len(operand) // 2
                f.rput(0x2200, bytes([1, 8, count, 0, 8, 0x60 | opcode]) + operand)
                self.assertEqual(expected, self.inspect(f)["unwind"]["records"][0]["operations"][0]["operandBytes"])

    def test_frame_declaration(self):
        f = self.fixture(); f.rput(0x2200, bytes([1, 8, 1, 0x25, 8, 3]))
        record = self.inspect(f)["unwind"]["records"][0]
        self.assertEqual((5, 32), (record["frameRegister"], record["frameOffsetBytes"]))

    def test_machine_frame_encodings_are_metadata_only(self):
        for info in [0, 1]:
            f = self.fixture(); f.rput(0x2200, bytes([1, 8, 1, 0, 8, (info << 4) | 10]))
            self.assertEqual(info, self.inspect(f)["unwind"]["records"][0]["operations"][0]["opInfo"])

    def test_handler_odd_slot_padding(self):
        f = self.fixture(); f.rput(0x2200, bytes([9, 8, 1, 0, 8, 2, 0xEF, 0xBE]))
        f.rpack(0x2208, "<I", 0x1010)
        record = self.inspect(f)["unwind"]["records"][0]
        self.assertEqual(0x1010, record["handlerRva"])
        self.assertEqual(0x220C, record["opaqueHandlerDataRva"])

    def test_chained_record(self):
        f = self.fixture(); f.rput(0x2200, bytes([33, 0, 0, 0]))
        f.rpack(0x2204, "<III", 0x1000, 0x1040, 0x2300)
        f.rput(0x2300, bytes([1, 8, 1, 0, 8, 2]))
        result = self.inspect(f)["unwind"]
        self.assertEqual(2, len(result["records"]))
        self.assertEqual(1, result["operationCount"])

    def test_shared_records_decoded_once(self):
        f = self.fixture(2); f.rpack(0x2114, "<I", 0x2200)
        result = self.inspect(f)["unwind"]
        self.assertEqual(2, len(result["functions"]))
        self.assertEqual(1, len(result["records"]))

    def test_no_exception_directory(self):
        f = self.fixture(); f.directory(3, 0, 0)
        self.assertEqual([], self.inspect(f)["unwind"]["records"])

    def test_foreign_architecture(self):
        f = Fixture(bits=32, imports=False, delay=False, tls=False)
        self.rejects(f, "unsupported-architecture")

    def test_invalid_table_size(self):
        f = self.fixture(); f.directory(3, 0x2100, 13)
        self.rejects(f, "invalid-unwind-table")

    def test_table_order(self):
        f = self.fixture(2); f.rpack(0x210C, "<I", 0x1000)
        self.rejects(f, "invalid-unwind-table")

    def test_non_executable_function(self):
        f = self.fixture(); f.rpack(0x2100, "<III", 0x2300, 0x2340, 0x2200)
        self.rejects(f, "invalid-runtime-function")

    def test_invalid_range(self):
        f = self.fixture(); f.rpack(0x2104, "<I", 0x1000)
        self.rejects(f, "invalid-runtime-function")

    def test_unaligned_unwind(self):
        f = self.fixture(); f.rpack(0x2108, "<I", 0x2201)
        self.rejects(f, "invalid-runtime-function")

    def test_zero_fill_unwind(self):
        f = self.fixture(); f.rpack(0x2108, "<I", 0x4100)
        self.rejects(f, "unbacked-rva")

    def test_future_version_refused(self):
        for version in [0, 2, 3, 7]:
            f = self.fixture(); f.rput(0x2200, bytes([version]))
            self.rejects(f, "unsupported-unwind-version")

    def test_conflicting_flags(self):
        for flags in [5, 6, 7, 8, 31]:
            f = self.fixture(); f.rput(0x2200, bytes([(flags << 3) | 1]))
            self.rejects(f, "invalid-unwind-flags")

    def test_unknown_opcode(self):
        for opcode in [6, 7, 11, 15]:
            f = self.fixture(); f.rput(0x2205, bytes([opcode]))
            self.rejects(f, "unsupported-unwind-opcode")

    def test_truncated_operand_slots(self):
        f = self.fixture(); f.rput(0x2200, bytes([1, 8, 1, 0, 8, 0x11]))
        self.rejects(f, "truncated-unwind-operation")

    def test_bad_opinfo(self):
        for encoded in [0x21, 0x13, 0x2A]:
            f = self.fixture(); f.rput(0x2200, bytes([1, 8, 2, 0x05, 8, encoded]))
            self.rejects(f, "invalid-unwind-opinfo")

    def test_code_order_and_prolog(self):
        f = self.fixture(); f.rput(0x2206, bytes([9]))
        self.rejects(f, "invalid-unwind-order")
        f = self.fixture(); f.rput(0x2201, bytes([65]))
        self.rejects(f, "invalid-unwind-prolog")

    def test_frame_offset_without_register(self):
        f = self.fixture(); f.rput(0x2203, bytes([0x10]))
        self.rejects(f, "invalid-unwind-frame")

    def test_non_executable_handler(self):
        f = self.fixture(); f.rput(0x2200, bytes([9, 0, 0, 0])); f.rpack(0x2204, "<I", 0x2300)
        self.rejects(f, "invalid-unwind-handler")

    def test_chain_cycle(self):
        f = self.fixture(); f.rput(0x2200, bytes([33, 0, 0, 0])); f.rpack(0x2204, "<III", 0x1000, 0x1040, 0x2200)
        self.rejects(f, "unwind-chain-cycle")

    def test_chained_frame_mismatch(self):
        f = self.fixture(); f.rput(0x2200, bytes([33, 0, 0, 0])); f.rpack(0x2204, "<III", 0x1000, 0x1040, 0x2300)
        f.rput(0x2300, bytes([1, 0, 0, 5]))
        self.rejects(f, "invalid-unwind-chain")

    def test_nonvolatile_register_contracts(self):
        for frame in [1, 2, 4, 8, 11]:
            f = self.fixture(); f.rput(0x2203, bytes([frame]))
            self.rejects(f, "unsupported-unwind-register")
        for encoded in [0x00, 0x14, 0x25, 0x08, 0x59]:
            f = self.fixture(); f.rput(0x2205, bytes([encoded]))
            self.rejects(f, "unsupported-unwind-register")

    def test_operand_alignment_and_zero_allocation(self):
        for encoded, data in [(0x11, b"\x01\x00\x00\x00"), (0x35, b"\x01\x00\x00\x00"),
                              (0x69, b"\x08\x00\x00\x00"), (0x11, b"\0\0\0\0")]:
            f = self.fixture(); f.rput(0x2200, bytes([1, 8, 3, 0, 8, encoded]) + data)
            self.rejects(f, "invalid-unwind-operand")

    def test_secondary_chain_must_not_add_stack_allocation(self):
        f = self.fixture(); f.rput(0x2200, bytes([33, 8, 1, 0, 8, 2]))
        self.rejects(f, "unsupported-unwind-chain-operation")

    def test_output_budget_applies_to_actual_pretty_json_and_newline(self):
        f = self.fixture(); result = self.inspect(f)
        import json
        exact = json.dumps(result, indent=2)
        with patch.object(uw, "MAX_OUTPUT_BYTES", len(exact.encode()) + 1):
            self.assertEqual(exact, uw.inspect_unwind_file(self.path, serialized=True))
        with patch.object(uw, "MAX_OUTPUT_BYTES", len(exact.encode())):
            self.rejects(f, "resource-limit")

    def test_resource_budgets(self):
        for constant, value in [("MAX_FUNCTIONS", 0), ("MAX_UNWIND_RECORDS", 0), ("MAX_OPERATIONS", 1),
                                ("MAX_CHAIN_DEPTH", 0), ("MAX_OUTPUT_BYTES", 1)]:
            with self.subTest(constant=constant), patch.object(uw, constant, value):
                with self.assertRaises(uw.PEError): self.inspect(self.fixture())

    def test_symlink_is_never_followed(self):
        alias = Path(self.scratch.name) / "alias.dll"
        self.path.write_bytes(self.fixture().data)
        alias.symlink_to(self.path)
        try:
            with self.assertRaises(OSError): uw.inspect_unwind_file(alias)
        finally:
            alias.unlink()


if __name__ == "__main__":
    unittest.main()
