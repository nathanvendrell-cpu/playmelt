"""Own tiny source-generated DllMain; no external DLL, CRT, TLS or exception bytes."""
import struct

from module_fixture import _empty_fixture
from probe_fixture import DATA, RDATA, TEXT


def make_dll_lifecycle_fixture(attach_success=True):
    image = _empty_fixture(dll=True)
    def w(offset, fmt, *values):
        struct.pack_into("<" + fmt, image, offset, *values)
    w(0x98 + 16, "I", TEXT)
    w(0x98 + 112 + 8, "II", RDATA, 40)
    w(0x98 + 112 + 12 * 8, "II", RDATA + 0x180, 16)
    w(0x600, "IIIII", RDATA + 0x100, 0, 0, RDATA + 0x80, RDATA + 0x180)
    dll = b"playmelt_fixture.dll\0"
    image[0x680:0x680 + len(dll)] = dll
    name = b"\0\0ProbeLifecycleCheckpoint\0"
    image[0x800:0x800 + len(name)] = name
    w(0x700, "Q", RDATA + 0x200)
    w(0x780, "Q", RDATA + 0x200)
    w(0xA10, "I", 1 if attach_success else 0)
    code = bytearray()
    def emit(hex_bytes):
        code.extend(bytes.fromhex(hex_bytes))
    def rip(opcode, target):
        emit(opcode)
        code.extend(struct.pack("<i", target - (TEXT + len(code) + 4)))
    emit("4883ec28")  # 32-byte Win64 shadow space and 16-byte call alignment.
    rip("48890d", DATA + 0x20)  # Record actual base argument, not an assumed base.
    rip("8915", DATA + 0x28)    # Record actual notification reason.
    rip("4c8905", DATA + 0x30)  # Record reserved argument (must be NULL).
    rip("8b05", DATA + 0x38)    # Number of calls; clamp log writes to four slots.
    emit("83f804 730d")         # cmp eax,4; jae skip 13-byte record sequence
    rip("4c8d0d", DATA + 0x40)
    emit("41891481 ffc0")       # mov [r9+rax*4],edx; inc eax
    rip("8905", DATA + 0x38)
    # RCX/RDX/R8 are unchanged; verify real arguments and busy-state refusals in C.
    rip("ff15", RDATA + 0x180)
    rip("8b05", DATA + 0x28)
    emit("83f801 7508")         # cmp eax,1; jne zero return (detach BOOL ignored)
    rip("8b05", DATA + 0x10)
    emit("eb02 31c0 4883c428 c3")
    assert len(code) <= 0x200
    image[0x400:0x400 + len(code)] = code
    assert len(image) == 3584
    return bytes(image)
