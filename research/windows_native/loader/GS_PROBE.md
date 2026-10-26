# Child-only Darwin ↔ guest GS experiment

`python3 research/windows_native/loader/run_gs_probe.py` builds sequentially at
nice 15, runs host validation tests and a disposable x86_64 child, then removes
its exact temporary directory under `Products.noindex`. It accepts no file or
executable input. The JSON receipt records commands, source hashes, PID/PGID,
negative controls, outcome and cleanup. Keep each attempt separately under
`work/`; `UNSUPPORTED` is an observed limit, never a passed GS transition.

The private Apple x86_64 `_thread_set_tsd_base` protocol is Machdep syscall 3,
with the syscall class in bits 24–31 and ESI zero. The assembly invokes this
protocol directly, without dynamic linking or calling libc while guest GS is
installed. Apple’s own test obtains the original base from
`thread_info(THREAD_IDENTIFIER_INFO).thread_handle`; our preflight also uses a
bounded Mach read and compares four words to actual `GS:` reads and
`pthread_self()`. No pthread structure offset is guessed.

The fixture slab models only `Self` at 0x30, a TLS-vector pointer at 0x58 and a
distinct LastError test field at 0x68. Two actual `GS:` reads reach vector index 1
and update its small data block. These fields are a controlled test layout,
not a complete or validated Windows TEB. This does **not** implement PE TLS
templates, `_tls_index`, TLS callbacks, CRT startup, Windows threads, or a PE
loader. No PE is loaded; the source assembly performs an import-style Win64
call through an explicit host-provided function pointer.

The gateway saves Win64 nonvolatile GPRs and XMM6–15, restores Darwin GS in
assembly, checks four restored slots, then calls one SysV host callback. That
callback checks `pthread_self`, the address/value of `errno`, and the base from
a new Mach thread-info query. It deliberately clobbers SysV-volatile RDI/RSI
and XMM6–15. The guest sentinels are checked before the next call and after the
final return. Guest GS is reinstalled before returning to the guest span;
Darwin GS is restored and checked before returning to host C. A failed setter
tries restoration, and restoration that cannot be verified terminates only
the child via an assembly syscall; it never returns to C with an unknown GS.

Host-only unit tests have ASan/UBSan and cannot invoke the switch through their
compiled `main`. The real switching child intentionally has **no sanitizer
runtime**: fatal signals use SIG_DFL and cannot invoke an instrumented C signal
handler with guest GS. Other catchable signals are blocked during the interval;
the original mask is restored afterwards. Synchronous faults, SIGILL and
timeouts are captured by the parent runner, not recovered in guest state.
The parent’s GS is never changed. SIGILL means UNSUPPORTED; SIGSEGV/SIGBUS or
unconfirmed restoration mean failure. Negative controls deliberately exercise
unavailable/SIGILL/timeout handling before the real experiment.
These forced controls run before changing GS: they test reporting and child
confinement, not recovery from a fault with guest GS installed. A normal return
may report UNSUPPORTED only if host GS, pthread/errno and signal mask restoration
were confirmed; otherwise it reports failure.

This is a single-thread normal-transition experiment, not a game compatibility
test. Asynchronous signal delivery, exceptions, cancellation, reentrant imports,
Windows-generated threads, multiple concurrent GS contexts, AVX upper halves,
SEH/TEB-wide semantics and real CRT initialization remain unqualified. The
private mechanism may differ or disappear across macOS/Rosetta versions. A
working transition would only remove one architectural uncertainty, not the
remaining startup or graphics requirements. No game, Wine, VM, GPU, framework
initialization, or installed-app change is performed.

Primary sources pinned to Apple XNU `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`:

- [x86_64 setter implementation](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/libsyscall/custom/custom.s#L118)
- [Syscall class and trap definitions](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/mach/i386/syscall_sw.h#L135)
- [Apple test: thread_handle as GS base](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/tests/ldt.c#L237)
- [Apple direct GS-based TSD access, explicitly private](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/libsyscall/os/tsd.h#L110)
- [Microsoft PE TLS initialization requirements](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#the-tls-section)
- [Microsoft x64 ABI, register and stack rules](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention)

No Apple test implementation or proprietary binary is copied into the fixture.
