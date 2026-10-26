"""Own embedded PE fixture only: no binary input, filesystem path or real DLL."""
import struct
from module_fixture import _empty_fixture
from probe_fixture import DATA, RDATA, TEXT


def make_module_filename_fixture():
    image = _empty_fixture()

    def w(offset, fmt, *values):
        struct.pack_into("<"+fmt, image, offset, *values)

    imports = ("GetModuleFileNameA", "GetModuleHandleA", "GetProcAddress",
               "SetLastError", "GetLastError")
    w(0x98+112+8, "II", RDATA, 40)
    w(0x98+112+12*8, "II", RDATA+0x180, 48)
    w(0x600, "IIIII", RDATA+0x100, 0, 0, RDATA+0x80, RDATA+0x180)
    image[0x680:0x68D] = b"kernel32.dll\0"
    cursor = 0x200
    for i, name in enumerate(imports):
        record = b"\0\0"+name.encode("ascii")+b"\0"
        image[0x600+cursor:0x600+cursor+len(record)] = record
        w(0x700+8*i, "Q", RDATA+cursor); w(0x780+8*i, "Q", RDATA+cursor)
        cursor += (len(record)+1) & ~1
    assert cursor <= 0x400
    for offset, raw in ((0x100,b"kernel32.dll\0"), (0x120,b"PROBE_MATH\0"),
                        (0x140,b"GetModuleFileNameA\0")):
        image[0xA00+offset:0xA00+offset+len(raw)] = raw
    code, failures = bytearray(), []

    def emit(raw):
        code.extend(bytes.fromhex(raw))

    def rip(op, target):
        emit(op); code.extend(struct.pack("<i", target-(TEXT+len(code)+4)))

    def rip_imm32(op, target, value):
        emit(op)
        code.extend(struct.pack("<iI", target-(TEXT+len(code)+4+4), value))

    def call(name):
        rip("ff15",RDATA+0x180+imports.index(name)*8)

    def fail_if(op):
        emit(op); failures.append(len(code)); code.extend(b"\0"*4)

    def record(offset):
        rip("8905",DATA+offset); call("GetLastError"); rip("8905",DATA+offset+4)

    # 32-byte shadow space, call-site stack aligned, no nonvolatile clobber.
    emit("4883ec28")
    rip("488d0d",DATA+0x100); call("GetModuleHandleA"); emit("4885c0"); fail_if("0f84")
    rip("488905",DATA+0x58); emit("4889c1"); rip("488d15",DATA+0x140); call("GetProcAddress")
    rip("488905",DATA+0x50)
    rip("483b05",DATA+0x48); fail_if("0f85")  # compare exact HOST function BEFORE dynamic call
    rip_imm32("c705",DATA+0x68,1)
    rip("488d0d",DATA+0x120); call("GetModuleHandleA"); emit("4885c0"); fail_if("0f84")
    rip("488905",DATA+0x60)
    emit("b945230000"); call("SetLastError")
    emit("31c9"); rip("488b15",DATA+0x20); emit("41b800020000"); call("GetModuleFileNameA"); record(0x70)
    rip("488b0d",DATA+0x60); rip("488b15",DATA+0x28); emit("41b804000000")
    rip("ff15",DATA+0x50); record(0x78)
    emit("b956340000"); call("SetLastError")
    rip("488b0d",DATA+0x60); rip("488b15",DATA+0x30); emit("41b8ffffffff")
    rip("ff15",DATA+0x50); record(0x80)
    emit("31c9"); rip("488b15",DATA+0x38); emit("4531c0"); call("GetModuleFileNameA"); record(0x88)
    emit("31c0 4883c428 c3")
    failed=len(code); emit("b801000000 4883c428 c3")
    for at in failures: struct.pack_into("<i",code,at,failed-(at+4))
    assert len(code)<=0x200, len(code)
    image[0x400:0x400+len(code)] = code
    assert len(image)==3584
    return bytes(image)
