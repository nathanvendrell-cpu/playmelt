"""Our embedded PE uses static module APIs, then dynamic memory APIs."""
import struct

from module_fixture import _empty_fixture
from probe_fixture import DATA, RDATA, TEXT


def make_combined_fixture():
    image = _empty_fixture()

    def w(offset, fmt, *values):
        struct.pack_into("<" + fmt, image, offset, *values)

    imports = ("GetModuleHandleA", "GetModuleHandleW", "GetProcAddress",
               "SetLastError", "GetLastError")
    w(0x98 + 112 + 8, "II", RDATA, 60)
    w(0x98 + 112 + 12 * 8, "II", RDATA + 0x180, 0x50)
    modules = (("kernel32.dll", 0x80, 0x100, 0x180, imports),
               ("playmelt_fixture.dll", 0xA0, 0x140, 0x1C0, ("CombinedCheckpoint",)))
    calls, cursor = {}, 0x200
    for module_index, (dll, name_rva, lookup, iat, symbols) in enumerate(modules):
        w(0x600 + 20*module_index, "IIIII", RDATA+lookup, 0, 0, RDATA+name_rva, RDATA+iat)
        encoded = dll.encode("ascii") + b"\0"
        image[0x600+name_rva:0x600+name_rva+len(encoded)] = encoded
        for index, name in enumerate(symbols):
            record = b"\0\0" + name.encode("ascii") + b"\0"
            image[0x600+cursor:0x600+cursor+len(record)] = record
            w(0x600+lookup+index*8, "Q", RDATA+cursor)
            w(0x600+iat+index*8, "Q", RDATA+cursor)
            calls[name] = RDATA+iat+index*8
            cursor += (len(record)+1) & ~1
    assert cursor <= 0x400
    strings = ((0x100, b"KERNEL32\0"), (0x120, "ntdll.dll\0".encode("utf-16le")),
               (0x140, b"VirtualProtect\0"), (0x160, b"NtQueryVirtualMemory\0"))
    for offset, value in strings:
        image[0xA00+offset:0xA00+offset+len(value)] = value
    code, failures = bytearray(), []

    def emit(raw):
        code.extend(bytes.fromhex(raw))

    def rip(opcode, address):
        emit(opcode)
        code.extend(struct.pack("<i", address-(TEXT+len(code)+4)))

    def call(name):
        rip("ff15", calls[name])

    def nonzero():
        emit("4885c0 0f84")
        failures.append(len(code)); code.extend(b"\0"*4)

    def checkpoint():
        call("CombinedCheckpoint"); nonzero()

    # RSP aligned for calls: 32-byte shadow plus arg5/arg6 at +32/+40.
    emit("4883ec38 b92211dec0"); call("SetLastError")
    for name, string, handle, symbol, function in (
        ("GetModuleHandleA", 0x100, 0x40, 0x140, 0x50),
        ("GetModuleHandleW", 0x120, 0x48, 0x160, 0x58),
    ):
        rip("488d0d", DATA+string); call(name); nonzero()
        rip("488905", DATA+handle)
        emit("4889c1"); rip("488d15", DATA+symbol); call("GetProcAddress"); nonzero()
        rip("488905", DATA+function)
    # Host validates EXACT dynamic function addresses before the guest calls any.
    checkpoint()
    for protection in (0x20, 0x04):
        rip("488b0d", DATA+0x20); emit("ba01000000 41b8")
        code.extend(struct.pack("<I", protection))
        rip("4c8b0d", DATA+0x28); rip("ff15", DATA+0x50)
        rip("8905", DATA+0x60)
        call("GetLastError"); rip("8905", DATA+0x64)
        emit("48c7c1ffffffff")
        rip("488b15", DATA+0x20); emit("4883c207 4531c0")
        rip("4c8b0d", DATA+0x30)
        emit("48c744242030000000")
        rip("488b05", DATA+0x38); emit("4889442428")
        rip("ff15", DATA+0x58); rip("8905", DATA+0x68)
        call("GetLastError"); rip("8905", DATA+0x6C)
        checkpoint()
    emit("31c0 4883c438 c3")
    failed = len(code)
    emit("b801000000 4883c438 c3")
    for offset in failures:
        struct.pack_into("<i", code, offset, failed-(offset+4))
    assert len(code) <= 0x200, len(code)
    image[0x400:0x400+len(code)] = code
    assert len(image) == 3584
    return bytes(image)
