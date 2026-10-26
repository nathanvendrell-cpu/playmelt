"""One embedded AMD64 EXE with a real TLS64 directory and no callbacks."""
from gs_pe_fixture import make_gs_pe_fixture


def make_tls_fixture():
    return make_gs_pe_fixture(tls=True)
