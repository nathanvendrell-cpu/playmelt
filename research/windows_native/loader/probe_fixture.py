"""Construct our tiny PE64 CPU fixture; never read a game or execute anything."""
import struct

IMAGE_BASE = 0x140000000
TEXT, RDATA, DATA, RELOC = 0x4000, 0x8000, 0xC000, 0x10000
IMPORTS = ("SetLastError", "GetLastError", "GetCurrentProcessId",
           "QueryPerformanceFrequency", "QueryPerformanceCounter",
           "GetTickCount64", "GetSystemTimeAsFileTime")
MAGIC = 0x1122334455667788


def make_fixture():
    image = bytearray(0xE00)
    def w(offset, fmt, *values):
        struct.pack_into("<" + fmt, image, offset, *values)
    image[:2] = b"MZ"; w(0x3C, "I", 0x80)
    image[0x80:0x84] = b"PE\0\0"
    w(0x84, "HHIIIHH", 0x8664, 4, 0, 0, 0, 0xF0, 0x22)
    o = 0x98
    w(o, "H", 0x20B)
    w(o + 4, "III", 0x200, 0x800, 0)
    w(o + 16, "IIQII", TEXT, TEXT, IMAGE_BASE, 0x4000, 0x200)
    w(o + 40, "HHHHHH", 6, 0, 0, 0, 6, 0)
    w(o + 56, "II", 0x14000, 0x400)
    w(o + 68, "HH", 3, 0x140)
    w(o + 72, "QQQQII", 0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
    w(o + 112 + 8, "II", RDATA, 40)
    w(o + 112 + 5 * 8, "II", RELOC, 12)
    w(o + 112 + 12 * 8, "II", RDATA + 0x180, (len(IMPORTS) + 1) * 8)
    sections = ((b".text", TEXT, 0x400, 0x200, 0x60000020),
                (b".rdata", RDATA, 0x600, 0x400, 0x40000040),
                (b".data", DATA, 0xA00, 0x200, 0xC0000040),
                (b".reloc", RELOC, 0xC00, 0x200, 0x42000040))
    for i, (name, rva, raw, size, flags) in enumerate(sections):
        at = o + 0xF0 + i * 40
        image[at:at+len(name)] = name
        w(at + 8, "IIIIIIHHI", size, rva, size, raw, 0, 0, 0, 0, flags)
    w(0x600, "IIIII", RDATA + 0x100, 0, 0, RDATA + 0x80, RDATA + 0x180)
    image[0x680:0x68D] = b"kernel32.dll\0"
    cursor = 0x200
    for i, name in enumerate(IMPORTS):
        entry = b"\0\0" + name.encode("ascii") + b"\0"
        image[0x600+cursor:0x600+cursor+len(entry)] = entry
        w(0x700 + 8*i, "Q", RDATA + cursor)
        w(0x780 + 8*i, "Q", RDATA + cursor)
        cursor += (len(entry) + 1) & ~1
    assert cursor <= 0x400
    w(0xA00, "QQ", IMAGE_BASE + DATA + 8, MAGIC)
    w(0xC00, "IIHH", DATA, 12, 0xA000, 0)

    code, failures = bytearray(), []
    def emit(data): code.extend(bytes.fromhex(data))
    def rip(opcode, target):
        emit(opcode)
        code.extend(struct.pack("<i", target - (TEXT + len(code) + 4)))
    def call(name): rip("ff15", RDATA + 0x180 + 8 * IMPORTS.index(name))
    def fail_if_zero():
        emit("85c0 0f84"); failures.append(len(code)); code.extend(b"\0"*4)
    emit("4883ec28")  # Win64 shadow space + 16-byte call alignment.
    rip("488b05", DATA)
    emit("488b10 48b9"); code.extend(struct.pack("<Q", MAGIC))
    emit("4839ca 0f85"); failures.append(len(code)); code.extend(b"\0"*4)
    emit("b9efbe0000"); call("SetLastError")
    call("GetCurrentProcessId"); rip("8905", DATA + 0x20)
    rip("488d0d", DATA + 0x28); call("QueryPerformanceFrequency"); fail_if_zero()
    rip("488d0d", DATA + 0x30); call("QueryPerformanceCounter"); fail_if_zero()
    rip("488d0d", DATA + 0x38); call("QueryPerformanceCounter"); fail_if_zero()
    call("GetTickCount64"); rip("488905", DATA + 0x40)
    rip("488d0d", DATA + 0x58); call("QueryPerformanceCounter"); fail_if_zero()
    rip("488d0d", DATA + 0x50); call("GetSystemTimeAsFileTime")
    call("GetLastError"); rip("8905", DATA + 0x48)
    emit("31c0 4883c428 c3")
    failure = len(code); emit("b801000000 4883c428 c3")
    for at in failures: struct.pack_into("<i", code, at, failure - (at + 4))
    assert len(code) <= 0x200
    image[0x400:0x400+len(code)] = code
    return bytes(image)
