"""Two source-generated PE fixtures; no external DLL or game bytes are used."""
import struct

from probe_fixture import DATA, RDATA, TEXT, make_fixture


def _empty_fixture(dll=False):
    image = bytearray(make_fixture())
    # Retain the validated section layout and DIR64 relocation of DATA[0].
    image[0x400:0xA00] = b"\0" * 0x600
    image[0xA10:0xC00] = b"\0" * 0x1F0
    struct.pack_into("<H", image, 0x96, 0x2022 if dll else 0x22)
    struct.pack_into("<I", image, 0x98 + 16, 0 if dll else TEXT)
    for directory in (0, 1, 12):
        struct.pack_into("<II", image, 0x98 + 112 + directory * 8, 0, 0)
    return image


def make_module_fixture():
    image = _empty_fixture(dll=True)
    def w(offset, fmt, *values):
        struct.pack_into("<" + fmt, image, offset, *values)
    def text_at(offset, text):
        data = text.encode("ascii") + b"\0"
        image[offset:offset + len(data)] = data

    w(0x98 + 112, "II", RDATA, 0x200)
    # Base 17 includes a nameless export at ordinal 18 and a hole at 22.
    w(0x600, "IIHHIIIIIII", 0, 0, 0, 0, RDATA + 0xC0, 17, 6, 4,
      RDATA + 0x40, RDATA + 0x60, RDATA + 0x70)
    w(0x640, "IIIIII", TEXT, TEXT + 0x10, RDATA + 0x110,
      RDATA + 0x140, DATA + 8, 0)
    names = (("Add", 0), ("GetHostPID", 2), ("MagicData", 4), ("ProductAgain", 3))
    cursor = 0x80
    for i, (name, ordinal_index) in enumerate(names):
        w(0x660 + 4 * i, "I", RDATA + cursor)
        w(0x670 + 2 * i, "H", ordinal_index)
        text_at(0x600 + cursor, name)
        cursor += len(name) + 1
    assert cursor <= 0xC0
    text_at(0x6C0, "probe_math.dll")
    text_at(0x710, "KERNEL32.GetCurrentProcessId")
    text_at(0x740, "probe_math.#18")
    image[0x400:0x404] = bytes.fromhex("8d0411 c3")  # lea eax,[rcx+rdx]; ret
    image[0x410:0x416] = bytes.fromhex("89c8 0fafc2 c3")  # imul eax,edx
    return bytes(image)


def make_module_client_fixture():
    image = _empty_fixture()
    def w(offset, fmt, *values):
        struct.pack_into("<" + fmt, image, offset, *values)
    imports = ("Add", 18, "GetHostPID", "ProductAgain", "MagicData")
    w(0x98 + 112 + 8, "II", RDATA, 40)
    w(0x98 + 112 + 12 * 8, "II", RDATA + 0x180, 48)
    w(0x600, "IIIII", RDATA + 0x100, 0, 0, RDATA + 0x80, RDATA + 0x180)
    image[0x680:0x68F] = b"probe_math.dll\0"
    cursor = 0x200
    for i, item in enumerate(imports):
        if isinstance(item, int):
            value = (1 << 63) | item
        else:
            name = b"\0\0" + item.encode("ascii") + b"\0"
            image[0x600 + cursor:0x600 + cursor + len(name)] = name
            value = RDATA + cursor
            cursor += (len(name) + 1) & ~1
        w(0x700 + 8 * i, "Q", value)
        w(0x780 + 8 * i, "Q", value)
    assert cursor <= 0x400
    code = bytearray()
    def emit(hex_bytes): code.extend(bytes.fromhex(hex_bytes))
    def rip(opcode, target):
        emit(opcode)
        code.extend(struct.pack("<i", target - (TEXT + len(code) + 4)))
    def call(index): rip("ff15", RDATA + 0x180 + 8 * index)
    emit("4883ec28")  # Win64 shadow space and 16-byte alignment for each call.
    emit("b913000000 ba17000000"); call(0); rip("8905", DATA + 0x20)
    emit("b906000000 ba07000000"); call(1); rip("8905", DATA + 0x24)
    call(2); rip("8905", DATA + 0x28)
    emit("b908000000 ba09000000"); call(3); rip("8905", DATA + 0x2C)
    rip("488b05", RDATA + 0x180 + 8 * 4); emit("488b00"); rip("488905", DATA + 0x30)
    emit("31c0 4883c428 c3")
    assert len(code) <= 0x200
    image[0x400:0x400 + len(code)] = code
    return bytes(image)
