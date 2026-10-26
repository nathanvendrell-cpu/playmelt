"""Our embedded PE: anonymous event, real wait and dynamic Set/Reset/Wait/Close."""
import struct
from module_fixture import _empty_fixture
from probe_fixture import DATA, RDATA, TEXT


def make_events_fixture():
    image = _empty_fixture()

    def w(at, fmt, *values):
        struct.pack_into("<"+fmt, image, at, *values)

    modules = (("kernel32.dll", 0x80, 0x100, 0x180,
                ("CreateEventExA", "GetModuleHandleA", "GetProcAddress", "SetLastError", "GetLastError")),
               ("playmelt_fixture.dll", 0xA0, 0x140, 0x1C0, ("EventsCheckpoint",)))
    w(0x98+112+8, "II", RDATA, 60)
    w(0x98+112+12*8, "II", RDATA+0x180, 0x50)
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
    for at, text in ((0x100, "SetEvent"), (0x120, "ResetEvent"),
                     (0x140, "WaitForSingleObject"), (0x160, "CloseHandle"), (0x180, "kernel32.dll")):
        raw = text.encode()+b"\0"; image[0xA00+at:0xA00+at+len(raw)] = raw
    code, failures = bytearray(), []

    def emit(raw): code.extend(bytes.fromhex(raw))

    def rip(opcode, address):
        emit(opcode); code.extend(struct.pack("<i", address-(TEXT+len(code)+4)))

    def call(name): rip("ff15", calls[name])

    def nonzero():
        emit("4885c0 0f84"); failures.append(len(code)); code.extend(b"\0"*4)

    def checkpoint(): call("EventsCheckpoint"); nonzero()

    def dynamic(slot, result, wait=None):
        rip("488b0d", DATA+0x40)
        if wait is not None:
            emit("ba"); code.extend(struct.pack("<I", wait))
        rip("ff15", DATA+slot); rip("8905", DATA+result)

    emit("4883ec28 b94433deac"); call("SetLastError")
    rip("488d0d", DATA+0x180); call("GetModuleHandleA"); nonzero(); rip("488905", DATA+0x48)
    for text_at, slot in ((0x100, 0x20), (0x120, 0x28), (0x140, 0x30), (0x160, 0x38)):
        rip("488b0d", DATA+0x48); rip("488d15", DATA+text_at)
        call("GetProcAddress"); nonzero(); rip("488905", DATA+slot)
    emit("31c9 31d2 4531c0 41b902001000"); call("CreateEventExA"); nonzero(); rip("488905", DATA+0x40)
    call("GetLastError"); rip("8905", DATA+0x70)
    checkpoint()  # Host compares every dynamically resolved address BEFORE calls.
    dynamic(0x30, 0x50, 100); checkpoint()  # Real condvar wait, notified by host pthread.
    dynamic(0x28, 0x54); dynamic(0x30, 0x58, 0)
    dynamic(0x20, 0x5C); dynamic(0x30, 0x60, 0); dynamic(0x30, 0x64, 0)
    call("GetLastError"); rip("8905", DATA+0x74)
    dynamic(0x38, 0x68); dynamic(0x30, 0x6C, 0)
    call("GetLastError"); rip("8905", DATA+0x78)
    checkpoint()
    emit("31c0 4883c428 c3")
    failed = len(code); emit("b801000000 4883c428 c3")
    for at in failures: struct.pack_into("<i", code, at, failed-(at+4))
    assert len(code) <= 0x200, len(code)
    image[0x400:0x400+len(code)] = code
    assert len(image) == 3584
    return bytes(image)
