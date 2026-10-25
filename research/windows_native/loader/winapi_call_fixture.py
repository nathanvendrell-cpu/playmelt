"""Our synthetic PE calls module APIs; never reads an external executable."""
import struct

from module_fixture import _empty_fixture
from probe_fixture import DATA, RDATA, TEXT


def make_winapi_call_fixture():
    image = _empty_fixture()

    def w(offset, fmt, *values):
        struct.pack_into("<" + fmt, image, offset, *values)

    imports = ("GetModuleHandleA", "GetModuleHandleW", "GetProcAddress",
               "SetLastError", "GetLastError")
    w(0x98 + 112 + 8, "II", RDATA, 40)
    w(0x98 + 112 + 12 * 8, "II", RDATA + 0x180, 48)
    w(0x600, "IIIII", RDATA + 0x100, 0, 0, RDATA + 0x80, RDATA + 0x180)
    image[0x680:0x68D] = b"kernel32.dll\0"
    cursor = 0x200
    for i, name in enumerate(imports):
        entry = b"\0\0" + name.encode("ascii") + b"\0"
        image[0x600 + cursor:0x600 + cursor + len(entry)] = entry
        w(0x700 + 8 * i, "Q", RDATA + cursor)
        w(0x780 + 8 * i, "Q", RDATA + cursor)
        cursor += (len(entry) + 1) & ~1
    assert cursor <= 0x400
    strings = {
        "module": (0x100, b"PROBE_MATH\0"),
        "wide": (0x120, "probe_math.dll\0".encode("utf-16le")),
        "add": (0x140, b"Add\0"),
        "pid": (0x150, b"GetHostPID\0"),
        "data": (0x160, b"MagicData\0"),
        "absent": (0x170, b"Missing\0"),
        "host": (0x180, b"kernel32\0"),
        "getmodule": (0x190, b"GetModuleHandleA\0"),
    }
    for offset, raw in strings.values():
        assert offset + len(raw) <= 0x200
        image[0xA00 + offset:0xA00 + offset + len(raw)] = raw

    code, failures = bytearray(), []

    def emit(hex_bytes):
        code.extend(bytes.fromhex(hex_bytes))

    def rip(opcode, target):
        emit(opcode)
        code.extend(struct.pack("<i", target - (TEXT + len(code) + 4)))

    def call(name):
        rip("ff15", RDATA + 0x180 + 8 * imports.index(name))

    def nonnull():
        emit("4885c0 0f84")
        failures.append(len(code))
        code.extend(b"\0" * 4)

    def get_export(symbol=None, ordinal=None):
        rip("488b0d", DATA + 0x28)
        if ordinal is not None:
            emit("ba")
            code.extend(struct.pack("<I", ordinal))
        else:
            rip("488d15", DATA + strings[symbol][0])
        call("GetProcAddress")
        nonnull()

    emit("4883ec28")  # Win64 shadow space and alignment; no nonvolatile register modified.
    emit("b9efbe0000"); call("SetLastError")
    emit("31c9"); call("GetModuleHandleA"); nonnull(); rip("488905", DATA + 0x20)
    rip("488d0d", DATA + strings["module"][0]); call("GetModuleHandleA")
    nonnull(); rip("488905", DATA + 0x28)
    rip("488d0d", DATA + strings["wide"][0]); call("GetModuleHandleW")
    nonnull(); rip("488905", DATA + 0x30)
    get_export("add"); emit("b913000000 ba17000000 ffd0"); rip("8905", DATA + 0x38)
    get_export(ordinal=18); emit("b906000000 ba07000000 ffd0"); rip("8905", DATA + 0x3C)
    get_export("pid"); emit("ffd0"); rip("8905", DATA + 0x40)
    get_export("data"); emit("488b00"); rip("488905", DATA + 0x48)
    call("GetLastError"); rip("8905", DATA + 0x58)
    rip("488b0d", DATA + 0x28); rip("488d15", DATA + strings["absent"][0])
    call("GetProcAddress"); rip("488905", DATA + 0x68)
    call("GetLastError"); rip("8905", DATA + 0x50)
    emit("b901000000"); rip("488d15", DATA + strings["add"][0])
    call("GetProcAddress"); rip("488905", DATA + 0x70)
    call("GetLastError"); rip("8905", DATA + 0x54)
    rip("488d0d", DATA + strings["host"][0]); call("GetModuleHandleA"); nonnull()
    emit("4889c1"); rip("488d15", DATA + strings["getmodule"][0])
    call("GetProcAddress"); nonnull(); emit("31c9 ffd0"); rip("488905", DATA + 0x60)
    emit("31c0 4883c428 c3")
    failed = len(code)
    emit("b801000000 4883c428 c3")
    for at in failures:
        struct.pack_into("<i", code, at, failed - (at + 4))
    assert len(code) <= 0x200
    image[0x400:0x400 + len(code)] = code
    return bytes(image)
