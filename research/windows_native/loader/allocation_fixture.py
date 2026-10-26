"""Embedded PE allocates, reads/writes data, protects/queries, dynamically frees."""
import struct
from module_fixture import _empty_fixture
from probe_fixture import DATA, RDATA, TEXT


def make_allocation_fixture():
    image = _empty_fixture()

    def w(at, fmt, *values):
        struct.pack_into("<"+fmt, image, at, *values)

    kernel = ("VirtualAlloc", "VirtualProtect", "GetModuleHandleA", "GetProcAddress", "SetLastError", "GetLastError")
    modules = (("kernel32.dll", 0x80, 0x100, 0x180, kernel),
               ("ntdll.dll", 0x90, 0x140, 0x1C0, ("NtQueryVirtualMemory",)),
               ("playmelt_fixture.dll", 0xA0, 0x160, 0x1E0, ("AllocationCheckpoint",)))
    w(0x98+112+8, "II", RDATA, 80)
    w(0x98+112+12*8, "II", RDATA+0x180, 0x70)
    calls, cursor = {}, 0x200
    for module_index, (dll, name_at, lookup, iat, names) in enumerate(modules):
        w(0x600+20*module_index, "IIIII", RDATA+lookup, 0, 0, RDATA+name_at, RDATA+iat)
        raw = dll.encode()+b"\0"; image[0x600+name_at:0x600+name_at+len(raw)] = raw
        for i, name in enumerate(names):
            raw = b"\0\0"+name.encode()+b"\0"
            image[0x600+cursor:0x600+cursor+len(raw)] = raw
            w(0x600+lookup+8*i, "Q", RDATA+cursor); w(0x600+iat+8*i, "Q", RDATA+cursor)
            calls[name] = RDATA+iat+8*i
            cursor += (len(raw)+1) & ~1
    assert cursor <= 0x400
    for at, raw in ((0x100, b"kernel32.dll\0"), (0x120, b"VirtualFree\0")):
        image[0xA00+at:0xA00+at+len(raw)] = raw
    code, failures = bytearray(), []

    def emit(raw): code.extend(bytes.fromhex(raw))

    def rip(opcode, address):
        emit(opcode); code.extend(struct.pack("<i", address-(TEXT+len(code)+4)))

    def call(name): rip("ff15", calls[name])

    def nonzero():
        emit("4885c0 0f84"); failures.append(len(code)); code.extend(b"\0"*4)

    def checkpoint(): call("AllocationCheckpoint"); nonzero()

    def query(status_slot):
        emit("48c7c1ffffffff"); rip("488b15", DATA+0x38); emit("4883c203 4531c0")
        rip("4c8b0d", DATA+0x28)
        emit("48c744242030000000"); rip("488b05", DATA+0x30); emit("4889442428")
        call("NtQueryVirtualMemory"); rip("8905", DATA+status_slot)
        call("GetLastError"); rip("8905", DATA+0x6C)

    emit("4883ec38 b94433deac"); call("SetLastError")
    rip("488d0d", DATA+0x100); call("GetModuleHandleA"); nonzero(); rip("488905", DATA+0x48)
    emit("4889c1"); rip("488d15", DATA+0x120); call("GetProcAddress"); nonzero(); rip("488905", DATA+0x40)
    emit("31c9 ba25000000 41b800300000 41b904000000"); call("VirtualAlloc"); nonzero(); rip("488905", DATA+0x38)
    call("GetLastError"); rip("8905", DATA+0x50)
    checkpoint()  # Validates dynamic Free address + full zero fill BEFORE guest writes.
    rip("488b05", DATA+0x38)
    emit("badf9b5713 8910 448b10"); rip("448915", DATA+0x58); emit("c640247b")
    rip("488b0d", DATA+0x38); emit("ba01000000 41b802000000"); rip("4c8b0d", DATA+0x20)
    call("VirtualProtect"); rip("8905", DATA+0x5C)
    query(0x60); checkpoint()
    rip("488b0d", DATA+0x38); emit("31d2 41b800800000"); rip("ff15", DATA+0x40); rip("8905", DATA+0x64)
    query(0x68); checkpoint()  # No old pointer is dereferenced after Free.
    emit("31c0 4883c438 c3")
    failed = len(code); emit("b801000000 4883c438 c3")
    for at in failures: struct.pack_into("<i", code, at, failed-(at+4))
    assert len(code) <= 0x200, len(code)
    image[0x400:0x400+len(code)] = code
    assert len(image) == 3584
    return bytes(image)
