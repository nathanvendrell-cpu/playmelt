"""Own PE caller and two callees capture state; no saved PC is resumed."""
import struct

from module_fixture import _empty_fixture
from probe_fixture import DATA, RDATA, TEXT

RBX_SENTINEL = 0x1122334455667788
R12_SENTINEL = 0x8877665544332211
CAPTURE = DATA + 0x60


def make_unwind_fixture():
    image = _empty_fixture()

    def w(offset, fmt, *values):
        struct.pack_into("<" + fmt, image, offset, *values)

    w(0x98 + 112 + 8, "II", RDATA, 40)
    w(0x98 + 112 + 12 * 8, "II", RDATA + 0x180, 16)
    w(0x600, "IIIII", RDATA + 0x100, 0, 0, RDATA + 0x80, RDATA + 0x180)
    dll = b"playmelt_fixture.dll\0"
    image[0x680:0x680 + len(dll)] = dll
    name = b"\0\0UnwindCheckpoint\0"
    image[0x800:0x800 + len(name)] = name
    w(0x700, "Q", RDATA + 0x200); w(0x780, "Q", RDATA + 0x200)
    # No PE exception directory is enabled; the strict loader remains unchanged.
    outer_info = bytes((1, 7, 3, 0, 7, 0x42, 3, 0xC0, 1, 0x30, 0, 0))
    small_info = outer_info
    large_info = bytes((1, 10, 4, 0, 10, 1, 37, 0, 3, 0xC0, 1, 0x30))
    for offset, info in ((0x250, outer_info), (0x260, small_info), (0x270, large_info)):
        image[0x600 + offset:0x600 + offset + len(info)] = info

    code = bytearray()

    def emit(raw):
        code.extend(bytes.fromhex(raw))

    def rip(opcode, target):
        emit(opcode)
        at = len(code); code.extend(struct.pack("<i", target-(TEXT+at+4)))
        return at

    def target(at, rva):
        struct.pack_into("<i", code, at, rva-(TEXT+at+4))

    def caller_slot():
        # Oracle is the caller's actual stack pointer BEFORE the CALL, not an
        # unwind-derived offset; expected return label is also stored beforehand.
        rip("488925", DATA + 0x20)
        label = rip("488d05", 0)
        rip("488905", DATA + 0x28)
        emit("e8"); call = len(code); code.extend(b"\0" * 4)
        return_label = TEXT + len(code)
        target(label, return_label)
        return call, return_label

    emit("53 4154 4883ec28")
    emit("48bb"); code.extend(struct.pack("<Q", RBX_SENTINEL))
    emit("49bc"); code.extend(struct.pack("<Q", R12_SENTINEL))
    small_call, small_return = caller_slot()
    emit("85c0 0f84"); abort = len(code); code.extend(b"\0" * 4)
    large_call, large_return = caller_slot()
    cleanup = TEXT + len(code)
    emit("4883c428 415c 5b c3")
    target(abort, cleanup)
    outer_end = TEXT + len(code)

    def callee(large):
        while len(code) % 16:
            emit("90")
        begin = TEXT + len(code)
        emit("53 4154")
        emit("4881ec28010000" if large else "4883ec28")
        # The captured values differ from saved caller sentinels: restoration
        # must actually read stack saves, not merely copy captured registers.
        emit("48bb"); code.extend(struct.pack("<Q", 0xAABBCCDDEEFF0011))
        emit("49bc"); code.extend(struct.pack("<Q", 0x1020304050607080))
        for reg in range(16):
            rex = 0x48 if reg < 8 else 0x4C
            modrm = 0x05 + ((reg & 7) << 3)
            rip(bytes((rex, 0x89, modrm)).hex(), CAPTURE + 8*reg)
        pc = rip("488d05", 0)
        rip("488905", CAPTURE + 128)  # RIP of the upcoming checkpoint boundary.
        rip("488905", CAPTURE)        # RAX now equals that label; keep context exact.
        marker = TEXT + len(code)
        target(pc, marker)
        rip("488d0d", CAPTURE)
        rip("ff15", RDATA + 0x180)
        emit("4881c428010000" if large else "4883c428")
        emit("415c 5b c3")
        return begin, TEXT + len(code), marker

    small_begin, small_end, small_capture = callee(False)
    large_begin, large_end, large_capture = callee(True)
    target(small_call, small_begin); target(large_call, large_begin)
    assert len(code) <= 0x200, len(code)
    image[0x400:0x400 + len(code)] = code
    assert len(image) == 3584
    functions = ((TEXT, outer_end, RDATA + 0x250),
                 (small_begin, small_end, RDATA + 0x260),
                 (large_begin, large_end, RDATA + 0x270))
    return bytes(image), functions, (small_return, large_return), (small_capture, large_capture)
