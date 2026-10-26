# Single-module PE TLS initialization experiment

`python3 research/windows_native/loader/run_tls_probe.py` builds sequentially at
nice15 and records hashes, commands, PID/PGID and cleanup. Inert TLS/loader/holds/
unwind-loader tests and the existing synthetic DLL lifecycle regression use
ASan/UBSan. GS children intentionally have no sanitizer signal runtime, as
described in GS_PROBE.md. The only executable inputs are source-generated
embedded fixtures. Temporary headers/binaries stay under Products.noindex.

`pm_pe_load_synthetic_tls_exe` is a separate explicit opt-in. The default loader,
synthetic DLL loader and unwind EXE loader still reject directory9. This mode
requires an EXE <=1MiB, an actual40-byte TLS64 directory, a nonempty template,
and template+zero-fill <=4096 bytes. Alignment1..64 is accepted; unspecified
alignment uses16 as our conservative subset choice, not a universal Windows
requirement. Reserved characteristic bits, DLLs, nonempty callbacks and other
unsupported directories remain refusals. Callback VA0 or a readable zero qword
is accepted; no callback is invoked.

TLS VA fields are normalized from immutable source and each nonzero field must
have its exact DIR64 relocation, including when relocation delta is zero.
Directory/template/empty callback table must be disjoint file-backed R ranges
on final R host pages. The index must be a separate aligned DWORD on RW/nonX.
All other relocation/IAT writes intersecting these TLS ranges, including IAT
zero terminators and partial overlaps, are rejected. After fixups, actual metadata/template/index bytes are
checked against the validated plan. Initialization copies the template into an
owned block, explicitly zeroes the tail, writes index1 in the image, and points
vector[1] to the block. No TLS directory is erased or ignored.

One bounded calloc contains control, block, alignment padding and a two-slot
vector. Ownership follows the original image/loading thread. Borrowed views
leave output unchanged on refusal. A failed unmap retains mapping/control/block
and enters cleanup-only; retry unload releases them after OS unmap succeeds.
This also applies if load itself fails and its cleanup unmap fails. No view or
previously borrowed pointer may be used in cleanup-only state. The host must
restore Darwin GS and finish guest use before unload; arbitrary native callers,
concurrent lifetime changes, dangling copies and ABA are outside the contract.

The real PE fixture reads its assigned DWORD index via RIP, stores an independent
index marker, then uses the GS TLS vector with index*8. It verifies zero-fill,
changes its per-thread copy and calls the IAT gateway twice. The original template
remains unchanged. A second child deliberately refuses the first callback and
checks the immediate exit/restoration/unload path. The baseline non-TLS PE bytes
are checked byte-for-byte against the prior hash and run in both modes too.

This is actual initialization of one source-generated PE module on one host
thread. It is not general Windows TLS, CRT startup, callbacks/DllMain, dynamic
module slots, automatic thread initialization, SEH, reentrancy or game support.
The private Apple GS mechanism and signal limitations remain unchanged. No
Wine, VM, Steam, game, GPU, framework initialization or app installation occurs.

Primary format: [Microsoft PE TLS section](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#the-tls-section).
The published 0x2C offset/index*4 example is x86; this controlled x64 fixture
uses its already qualified GS0x58 slab and pointer stride8.
