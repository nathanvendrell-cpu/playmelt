# MacGameFix Spider-Man 2 performance candidate

Upstream: https://github.com/MathiasKowoll/MacGameFix, commit `c220184af8ac526b5cd325bbcc46276dc35564f3`, `fixes/sm2-tpose-fix.c`; this file identifies its MacGameVideoFix glue as GPL-3.0-or-later and credits macprotips' SpiderMan2Fix as public domain. Preserve upstream license and attribution when distributing this patch. The GPL text is preserved in `patches/COPYING.MacGameFix`; use the pinned upstream source when rebuilding the vendor component.

Apply `macgamefix-c220184-performance.patch` with `patch -p1` from a directory containing that exact `sm2-tpose-fix.c`. It stops the original-hook table scan at the already-unique match and reuses the already computed FNV-1 shader hash for fog identification and replacement logging. It does not change shaders, resource barriers, calls into D3D12 or shader bytes. The hash is still computed in the fallback when it was not previously computed.

This optional proxy is built separately; the application build does not bundle it or any game shader. The staging path is `Products.noindex/sm2-code-perf/amd_ags_x64.dll`. After preparing the pinned upstream source and the forwarder definition for the existing game library, build from the repository root with MinGW:

```sh
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -Wno-unused-parameter -Wno-cast-function-type -static -shared -Wl,--no-insert-timestamp -o Products.noindex/sm2-code-perf/amd_ags_x64.dll Products.noindex/sm2-code-perf/source/sm2-tpose-fix.c Products.noindex/sm2-code-perf/amd_ags_x64.def -lole32 -luuid
clang -O2 -Wall -Wextra -Werror tests/macgamefix-perf-check.c -o Products.noindex/macgamefix-perf-check
Products.noindex/macgamefix-perf-check
```

The standalone C test models the lookup and FNV-1/fog decisions rather than executing the actual Windows hook functions. It covers first, middle, last, absent and multiple-vtable keys, cached versus recomputed hashes, and the not-computed fallback. It does not exercise Windows locks, Wine, D3D12 or GPU. Its timings isolate lookup/hash work and do not predict frame rate or end-to-end performance. Shader bytes and GPU synchronization still need real-game verification after independent review.
