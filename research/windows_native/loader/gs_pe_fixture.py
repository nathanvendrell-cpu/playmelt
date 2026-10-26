"""Generate our strict PE64 GS fixture. No reading/executing external binaries."""
import struct
from probe_fixture import IMAGE_BASE, TEXT, RDATA, DATA, RELOC, make_fixture

IAT = RDATA + 0x180
MAGIC = 0x492a6e7c0506cafe
IMPORT_DLL = "playmelt_fixture.dll"
IMPORT_NAME = "GSCheckpoint"


def make_gs_pe_fixture():
    image = bytearray(0x1400)
    image[:0x400] = make_fixture()[:0x400]
    def w(at, fmt, *values): struct.pack_into("<"+fmt, image, at, *values)
    w(0x9C, "I", 0x800)  # SizeOfCode
    w(0x98+112+12*8, "II", IAT, 16)
    for i, (raw, size) in enumerate(((0x400, 0x800), (0xC00, 0x400), (0x1000, 0x200), (0x1200, 0x200))):
        at=0x188+i*40
        w(at+8, "I", size); w(at+16, "II", size, raw)
    w(0xC00, "IIIII", RDATA+0x100, 0, 0, RDATA+0x80, IAT)
    dll=IMPORT_DLL.encode()+b"\0"; image[0xC80:0xC80+len(dll)]=dll
    name=b"\0\0"+IMPORT_NAME.encode()+b"\0"; image[0xE00:0xE00+len(name)]=name
    w(0xD00, "Q", RDATA+0x200); w(0xD80, "Q", RDATA+0x200)
    for reg in range(6,16): image[0xE40+(reg-6)*16:0xE50+(reg-6)*16]=bytes([reg])*16
    w(0x1000,"QQ",IMAGE_BASE+DATA+8,MAGIC)
    w(0x1200,"IIHH",DATA,12,0xA000,0)
    code=bytearray(); failures=[]; callsites=[]; guards=[]
    def emit(s): code.extend(bytes.fromhex(s))
    def rip(op,target):
        emit(op); code.extend(struct.pack("<i",target-(TEXT+len(code)+4)))
    def rip_imm32(op,target,value):
        emit(op); code.extend(struct.pack("<iI",target-(TEXT+len(code)+8),value))
    def fail_if_ne():
        emit("0f85"); failures.append(len(code)); code.extend(b"\0"*4)
    def xmm_stack(reg, offset, load=False):
        emit("f3"+("44" if reg>=8 else "")+"0f"+("6f" if load else "7f"))
        code.extend(bytes([0x84|((reg&7)<<3),0x24])); code.extend(struct.pack("<I",offset))
    def snapshot():
        for slot,reg in enumerate((3,5,7,6,12,13,14,15)):
            code.extend(bytes([0x49|((reg>>3)<<2),0x89,0x84|((reg&7)<<3),0x24]))
            code.extend(struct.pack("<I",160+slot*8))
        for reg in range(6,16):
            code.extend(bytes([0xf3,0x41|((reg>>3)<<2),0x0f,0x7f,0x84|((reg&7)<<3),0x24]))
            code.extend(struct.pack("<I",224+(reg-6)*16))
    emit("53 55 57 56 4154 4155 4156 4157 4881ecd8000000")
    for reg in range(6,16): xmm_stack(reg,32+(reg-6)*16)
    emit("4989cc")  # R12 = Win64 argument context
    rip_imm32("c705",DATA+0x20,1)
    rip("488b05",DATA); emit("488b00 48ba"); code.extend(struct.pack("<Q",MAGIC)); emit("4839d0"); fail_if_ne()
    for reg,value in ((3,0x1357),(5,0x2468),(7,0x3579),(6,0x468a),(13,0x579b),(14,0x68ac),(15,0x79bd)):
        code.extend(bytes([0x48|(reg>>3),0xc7,0xc0|(reg&7)])); code.extend(struct.pack("<I",value))
    for reg in range(6,16): rip("f3"+("44" if reg>=8 else "")+"0f6f"+format(0x05|((reg&7)<<3),"02x"),RDATA+0x240+(reg-6)*16)
    for _ in range(2):
        emit("65488b042530000000 493b442408"); fail_if_ne()
        emit("65488b042558000000 493b442410"); fail_if_ne()
        emit("488b4008 493b442418"); fail_if_ne()
        emit("49ff842480000000 48830001 49ff842488000000")
        emit("65c704256800000010325476")
        snapshot(); rip("ff05",DATA+0x24); emit("4c89e1")
        callsites.append(TEXT+len(code)); rip("ff15",IAT)
        # FIRST instructions after IAT: check failure, before any further GS read.
        guards.append(TEXT+len(code)); emit("49837c246800"); fail_if_ne()
        rip("ff05",DATA+0x28)
    snapshot(); rip_imm32("c705",DATA+0x30,1); emit("31c0 e9")
    success_jump=len(code); code.extend(b"\0"*4)
    failure=len(code)
    snapshot()  # Post-IAT refusal snapshot uses plain memory only, never GS.
    rip_imm32("c705",DATA+0x38,1)
    emit("49837c246800 7509 49c744246801000000 b801000000")
    epilogue=len(code)
    for reg in range(6,16): xmm_stack(reg,32+(reg-6)*16,True)
    emit("4881c4d8000000 415f 415e 415d 415c 5e 5f 5d 5b c3")
    for at in failures: struct.pack_into("<i",code,at,failure-(at+4))
    struct.pack_into("<i",code,success_jump,epilogue-(success_jump+4))
    assert len(code)<=0x800, len(code)
    image[0x400:0x400+len(code)]=code
    return bytes(image),{"entryRVA":TEXT,"iatRVA":IAT,"callsiteRVAs":callsites,
                         "failureGuardRVAs":guards,"codeSize":len(code),"tlsDirectoryPresent":False}
