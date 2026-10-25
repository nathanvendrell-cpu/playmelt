"""Embed RUNTIME_FUNCTION entries in the PE; expose only independent PC oracles."""
import struct

from unwind_fixture import make_unwind_fixture, RBX_SENTINEL, R12_SENTINEL
from probe_fixture import RDATA


def make_embedded_unwind_fixture():
    original, functions, returns, captures = make_unwind_fixture()
    image = bytearray(original)
    table_offset = 0x300
    struct.pack_into("<II", image, 0x98+112+3*8, RDATA+table_offset, 12*len(functions))
    for index, entry in enumerate(functions):
        struct.pack_into("<III", image, 0x600+table_offset+12*index, *entry)
    # The loader MUST discover the catalogue from the original directory. No
    # strip step, optional-header rewrite to zero, or parallel C catalogue.
    return bytes(image), returns, captures
