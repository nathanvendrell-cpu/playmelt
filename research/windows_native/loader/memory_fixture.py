"""Embedded CPU-only PE that calls VirtualProtect on separately owned memory."""
import struct

from module_fixture import _empty_fixture
from probe_fixture import DATA, RDATA, TEXT


def make_memory_fixture():
    image = _empty_fixture()

    def w(offset, fmt, *values):
        struct.pack_into("<" + fmt, image, offset, *values)

    w(0x98 + 112 + 8, "II", RDATA, 60)
    w(0x98 + 112 + 12 * 8, "II", RDATA + 0x180, 0x50)
    w(0x600, "IIIII", RDATA + 0x100, 0, 0, RDATA + 0x80, RDATA + 0x180)
    w(0x614, "IIIII", RDATA + 0x130, 0, 0, RDATA + 0xA0, RDATA + 0x1C0)
    image[0x680:0x68D] = b"kernel32.dll\0"
    host = b"playmelt_fixture.dll\0"
    image[0x6A0:0x6A0 + len(host)] = host
    imports = ("VirtualProtect", "GetLastError", "SetLastError", "MemoryCheckpoint")
    cursor = 0x200
    for i, name in enumerate(imports):
        record = b"\0\0" + name.encode("ascii") + b"\0"
        image[0x600 + cursor:0x600 + cursor + len(record)] = record
        lookup, iat = (0x700 + 8*i, 0x780 + 8*i) if i < 3 else (0x730, 0x7C0)
        w(lookup, "Q", RDATA + cursor); w(iat, "Q", RDATA + cursor)
        cursor += (len(record) + 1) & ~1
    assert cursor <= 0x400
    code, failures = bytearray(), []

    def emit(raw):
        code.extend(bytes.fromhex(raw))

    def rip(opcode, target):
        emit(opcode)
        code.extend(struct.pack("<i", target - (TEXT + len(code) + 4)))

    def call(name):
        index = imports.index(name)
        rip("ff15", RDATA + (0x180 + 8*index if index < 3 else 0x1C0))

    def require(success):
        emit("85c0 0f84" if success else "85c0 0f85")
        failures.append(len(code)); code.extend(b"\0" * 4)

    def protect(protection, straddle=False):
        rip("488b0d", DATA + 0x20)  # target base
        rip("488b15", DATA + 0x28)  # host page size
        if straddle:
            emit("4801d1 48ffc9 ba02000000")  # base+page-1, size=2
        else:
            emit("48d1e2")  # size=two pages
        emit("41b8"); code.extend(struct.pack("<I", protection))
        rip("4c8b0d", DATA + 0x30)  # output in a DIFFERENT owned allocation
        call("VirtualProtect")

    emit("4883ec28")
    emit("b9feca0000"); call("SetLastError")
    protect(0x20, straddle=True); require(True)
    call("MemoryCheckpoint"); require(True)
    protect(0x04); require(True)
    call("MemoryCheckpoint"); require(True)
    call("GetLastError"); rip("8905", DATA + 0x48)
    protect(0x40); require(False)  # RWX must be rejected, never downgraded.
    call("GetLastError"); rip("8905", DATA + 0x50)
    call("MemoryCheckpoint"); require(True)
    emit("31c0 4883c428 c3")
    failed = len(code); emit("b801000000 4883c428 c3")
    for at in failures:
        struct.pack_into("<i", code, at, failed-(at+4))
    assert len(code) <= 0x200
    image[0x400:0x400 + len(code)] = code
    assert len(image) == 3584
    return bytes(image)
