"""Own synthetic DLL export fixture plus actual one-shot process notifications."""
import struct
from module_fixture import make_module_fixture, make_module_client_fixture
from probe_fixture import TEXT, DATA


def make_hold_dll_fixture():
    image=bytearray(make_module_fixture())
    entry=TEXT+0x60
    struct.pack_into("<I",image,0x98+16,entry)
    code=bytearray()

    def rip(op,target):
        code.extend(bytes.fromhex(op))
        code.extend(struct.pack("<i",target-(entry+len(code)+4)))

    # Leaf DllMain: record actual arguments/count, return TRUE. No imports/TLS.
    rip("48890d",DATA+0x20)
    rip("8915",DATA+0x28)  # base is 8 bytes at +20; reason at +28
    rip("4c8905",DATA+0x30)
    rip("ff05",DATA+0x38)
    code.extend(bytes.fromhex("b801000000 c3"))
    assert len(code)<0x100
    image[0x460:0x460+len(code)]=code
    assert len(image)==3584
    return bytes(image)


def make_hold_client_fixture():
    return make_module_client_fixture()
