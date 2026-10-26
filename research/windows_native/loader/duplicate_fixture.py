"""Own PE: DuplicateHandle seven args into owned output, then shared event state."""
import struct
from module_fixture import _empty_fixture
from probe_fixture import DATA, RDATA, TEXT


def make_duplicate_fixture():
    image = _empty_fixture()

    def w(at, fmt, *values):
        struct.pack_into("<"+fmt, image, at, *values)

    modules = (("kernel32.dll", 0x80, 0x100, 0x180,
                ("CreateEventExA", "GetModuleHandleA", "GetProcAddress", "SetEvent", "WaitForSingleObject", "CloseHandle", "GetLastError")),
               ("playmelt_fixture.dll", 0xA0, 0x160, 0x1E0, ("DuplicateCheckpoint",)))
    w(0x98+112+8, "II", RDATA, 60); w(0x98+112+12*8, "II", RDATA+0x180, 0x70)
    calls, cursor = {}, 0x200
    for module_index, (dll, name_at, lookup, iat, names) in enumerate(modules):
        w(0x600+20*module_index, "IIIII", RDATA+lookup, 0, 0, RDATA+name_at, RDATA+iat)
        raw = dll.encode()+b"\0"; image[0x600+name_at:0x600+name_at+len(raw)] = raw
        for i, name in enumerate(names):
            raw = b"\0\0"+name.encode()+b"\0"; image[0x600+cursor:0x600+cursor+len(raw)] = raw
            w(0x600+lookup+8*i, "Q", RDATA+cursor); w(0x600+iat+8*i, "Q", RDATA+cursor)
            calls[name] = RDATA+iat+8*i; cursor += (len(raw)+1) & ~1
    assert cursor <= 0x400
    for at, text in ((0x100, "DuplicateHandle"), (0x120, "kernel32.dll")):
        raw = text.encode()+b"\0"; image[0xA00+at:0xA00+at+len(raw)] = raw
    code, failures = bytearray(), []

    def emit(raw): code.extend(bytes.fromhex(raw))

    def rip(opcode, address):
        emit(opcode); code.extend(struct.pack("<i", address-(TEXT+len(code)+4)))

    def call(name): rip("ff15", calls[name])

    def nonzero(pointer=True):
        emit("4885c0 0f84" if pointer else "85c0 0f84")
        failures.append(len(code)); code.extend(b"\0"*4)

    def checkpoint(): call("DuplicateCheckpoint"); nonzero(False)

    def action(name, handle_at, result, wait=False):
        rip("488b0d", DATA+handle_at)
        if wait: emit("31d2")
        call(name); rip("8905", DATA+result)

    emit("4883ec38")
    rip("488d0d", DATA+0x120); call("GetModuleHandleA"); nonzero(); rip("488905", DATA+0x30)
    emit("4889c1"); rip("488d15", DATA+0x100); call("GetProcAddress"); nonzero(); rip("488905", DATA+0x20)
    emit("31c9 31d2 4531c0 41b902001000"); call("CreateEventExA"); nonzero(); rip("488905", DATA+0x40)
    checkpoint()  # Verify the dynamic address before executing it.
    emit("48c7c1ffffffff"); rip("488b15", DATA+0x40); emit("49c7c0ffffffff"); rip("4c8b0d", DATA+0x28)
    # Caller stack args5 desiredAccess SYNCHRONIZE,6 inheritance FALSE,7 options0.
    emit("c744242000001000 c744242800000000 c744243000000000")
    rip("ff15", DATA+0x20); rip("8905", DATA+0x50); nonzero(False)
    rip("488b05", DATA+0x28); emit("488b00"); rip("488905", DATA+0x48)
    checkpoint()
    action("SetEvent", 0x48, 0x54); call("GetLastError"); rip("8905", DATA+0x58)
    action("SetEvent", 0x40, 0x5C); action("WaitForSingleObject", 0x48, 0x60, True)
    action("WaitForSingleObject", 0x40, 0x64, True); action("CloseHandle", 0x40, 0x68)
    action("WaitForSingleObject", 0x48, 0x6C, True); action("CloseHandle", 0x48, 0x70)
    action("CloseHandle", 0x48, 0x74); call("GetLastError"); rip("8905", DATA+0x78)
    checkpoint()
    emit("31c0 4883c438 c3")
    failed = len(code); emit("b801000000 4883c438 c3")
    for at in failures: struct.pack_into("<i", code, at, failed-(at+4))
    assert len(code) <= 0x200, len(code)
    image[0x400:0x400+len(code)] = code
    assert len(image) == 3584
    return bytes(image)
