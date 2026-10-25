"""Source-generated, bounded PE: six-argument NtQueryVirtualMemory calls only."""
import struct

from module_fixture import _empty_fixture
from probe_fixture import DATA, RDATA, TEXT


def make_memory_query_fixture():
    image = _empty_fixture()

    def w(offset, fmt, *values):
        struct.pack_into("<" + fmt, image, offset, *values)

    w(0x98 + 112 + 8, "II", RDATA, 80)
    w(0x98 + 112 + 12 * 8, "II", RDATA + 0x180, 0x50)
    modules = (("ntdll.dll", 0x80, 0x100, 0x180, ("NtQueryVirtualMemory",)),
               ("kernel32.dll", 0x90, 0x120, 0x1A0, ("GetLastError", "SetLastError")),
               ("playmelt_fixture.dll", 0xA0, 0x140, 0x1C0, ("QueryCheckpoint",)))
    calls = {}
    cursor = 0x200
    for module_index, (dll, name_rva, lookup, iat, imports) in enumerate(modules):
        w(0x600 + 20 * module_index, "IIIII", RDATA + lookup, 0, 0,
          RDATA + name_rva, RDATA + iat)
        encoded = dll.encode("ascii") + b"\0"
        image[0x600 + name_rva:0x600 + name_rva + len(encoded)] = encoded
        for index, name in enumerate(imports):
            record = b"\0\0" + name.encode("ascii") + b"\0"
            image[0x600 + cursor:0x600 + cursor + len(record)] = record
            w(0x600 + lookup + index * 8, "Q", RDATA + cursor)
            w(0x600 + iat + index * 8, "Q", RDATA + cursor)
            calls[name] = RDATA + iat + index * 8
            cursor += (len(record) + 1) & ~1
    assert cursor <= 0x400
    code, failures = bytearray(), []

    def emit(raw):
        code.extend(bytes.fromhex(raw))

    def rip(opcode, target):
        emit(opcode)
        code.extend(struct.pack("<i", target - (TEXT + len(code) + 4)))

    def call(name):
        rip("ff15", calls[name])

    # At each call: aligned RSP, 32-byte shadow space, arg5 at +32, arg6 at +40.
    emit("4883ec38 b93412feca")
    call("SetLastError")
    for phase in range(5):
        emit("48c7c1ffffffff")  # RCX = current-process pseudo-handle, sign extended.
        rip("488b15", DATA + 0x20)  # RDX = owned target base.
        if phase != 4:
            rip("488b05", DATA + 0x28)
            emit("4801c2")
            if phase != 0:
                emit("4801c2")
        emit("4883c207 4531c0")  # address+7, R8D = MemoryBasicInformation.
        rip("4c8b0d", DATA + 0x30)  # R9 = intentionally unaligned output.
        emit("48c7442420")
        code.extend(struct.pack("<I", 47 if phase == 2 else 48))  # arg5 size.
        if phase == 3:
            emit("b801000000")  # inaccessible arg6 pointer, rejected before writes.
        elif phase == 4:
            emit("31c0")  # optional arg6 = NULL.
        else:
            rip("488b05", DATA + 0x38)
        emit("4889442428")  # arg6 ReturnLength, beyond the 32-byte shadow space.
        call("NtQueryVirtualMemory")
        rip("8905", DATA + 0x50)
        call("GetLastError")
        rip("8905", DATA + 0x54)
        call("QueryCheckpoint")
        emit("85c0 0f84")
        failures.append(len(code))
        code.extend(b"\0" * 4)
    emit("31c0 4883c438 c3")
    failed = len(code)
    emit("b801000000 4883c438 c3")
    for offset in failures:
        struct.pack_into("<i", code, offset, failed - (offset + 4))
    assert len(code) <= 0x200
    image[0x400:0x400 + len(code)] = code
    assert len(image) == 3584
    return bytes(image)
