/*
 * Synthetic equivalence and CPU microbenchmark for the lookup and FNV-1
 * changes in macgamefix-c220184-performance.patch. These are standalone
 * models, not calls to the compiled Windows hooks and not a GPU test.
 * Hash algorithm and lookup structure follow MathiasKowoll/MacGameFix,
 * commit c220184af8ac526b5cd325bbcc46276dc35564f3, sm2fix_core.c and
 * sm2-tpose-fix.c. The original fix credits macprotips/SpiderMan2Fix.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

struct entry { uintptr_t table; unsigned index; uintptr_t function; };
static struct entry entries[32];
static volatile uintptr_t sink;
static volatile uint64_t hash_sink;
static unsigned hash_calls;

__attribute__((noinline)) static uint64_t shader_hash(const void *data, size_t size)
{
    /* Volatile reads prevent the compiler merging two benchmark calls. */
    const volatile unsigned char *bytes = data;
    uint64_t hash = UINT64_C(0xcbf29ce484222325);
    for (size_t i = 0; i < size; ++i)
        hash = (hash * UINT64_C(0x100000001b3)) ^ bytes[i];
    return hash;
}
__attribute__((noinline)) static uintptr_t lookup_old(uintptr_t table, unsigned index)
{
    uintptr_t result = 0;
    for (unsigned i = 0; i < 32; ++i)
        if (entries[i].table == table && entries[i].index == index)
            result = entries[i].function;
    return result;
}
__attribute__((noinline)) static uintptr_t lookup_new(uintptr_t table, unsigned index)
{
    uintptr_t result = 0;
    for (unsigned i = 0; i < 32; ++i)
        if (entries[i].table == table && entries[i].index == index) {
            result = entries[i].function;
            break;
        }
    return result;
}
static uint64_t counted_hash(const void *data, size_t size)
{
    ++hash_calls;
    return shader_hash(data, size);
}
/* Models the original and new fog check after a prior replacement lookup. */
static int fog_old(const void *data, size_t size, int enabled, int has_pso, uint64_t target)
{
    if (!enabled || !has_pso || !data || size < 32) return 0;
    return counted_hash(data, size) == target;
}
static int fog_new(const void *data, size_t size, int enabled, int has_pso,
                   uint64_t target, uint64_t hash, int hashed)
{
    if (!enabled || !has_pso || !data || size < 32) return 0;
    if (!hashed) hash = counted_hash(data, size);
    return hash == target;
}
static double now_seconds(void)
{
    struct timespec t;
    assert(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return (double)t.tv_sec + (double)t.tv_nsec / 1000000000.0;
}
int main(void)
{
    for (unsigned i = 0; i < 32; ++i)
        entries[i] = (struct entry){i / 4 + 1, i % 4, 100 + i};
    /* Unique pairs: first, middle, last, missing index and missing table. */
    assert(lookup_old(1, 0) == lookup_new(1, 0) && lookup_new(1, 0) == 100);
    assert(lookup_old(5, 0) == lookup_new(5, 0) && lookup_new(5, 0) == 116);
    assert(lookup_old(8, 3) == lookup_new(8, 3) && lookup_new(8, 3) == 131);
    assert(lookup_old(1, 9) == 0 && lookup_new(1, 9) == 0);
    assert(lookup_old(9, 0) == 0 && lookup_new(9, 0) == 0);
    for (unsigned t = 0; t < 10; ++t)
        for (unsigned i = 0; i < 6; ++i)
            assert(lookup_old(t, i) == lookup_new(t, i));

    unsigned char bytes[256];
    for (unsigned i = 0; i < sizeof(bytes); ++i) bytes[i] = (unsigned char)(19 * i + 7);
    const uint64_t target = shader_hash(bytes, sizeof(bytes));
    for (int enabled = 0; enabled < 2; ++enabled)
        for (int pso = 0; pso < 2; ++pso)
            for (int matches = 0; matches < 2; ++matches) {
                uint64_t wanted = matches ? target : target ^ 1;
                hash_calls = 0;
                int old = fog_old(bytes, sizeof(bytes), enabled, pso, wanted);
                unsigned old_calls = hash_calls;
                hash_calls = 0;
                int fallback = fog_new(bytes, sizeof(bytes), enabled, pso, wanted, 0, 0);
                assert(old == fallback && hash_calls == old_calls);
                hash_calls = 0;
                int cached = fog_new(bytes, sizeof(bytes), enabled, pso, wanted, target, 1);
                assert(old == cached && hash_calls == 0);
            }
    hash_calls = 0;
    assert(!fog_old(bytes, 31, 1, 1, target));
    assert(!fog_new(bytes, 31, 1, 1, target, 0, 0));
    assert(hash_calls == 0);
    assert(!fog_new(NULL, 256, 1, 1, target, 0, 0));

    const unsigned iterations = 3000000;
    double start = now_seconds();
    for (unsigned i = 0; i < iterations; ++i) sink ^= lookup_old(1, i % 4);
    double middle = now_seconds();
    for (unsigned i = 0; i < iterations; ++i) sink ^= lookup_new(1, i % 4);
    double end = now_seconds();
    unsigned char block[65536];
    for (unsigned i = 0; i < sizeof(block); ++i) block[i] = (unsigned char)(7 * i);
    const unsigned rounds = 300;
    double a = now_seconds();
    for (unsigned i = 0; i < rounds; ++i) {
        block[i % sizeof(block)] = (unsigned char)i;
        hash_sink ^= shader_hash(block, sizeof(block));
        hash_sink ^= shader_hash(block, sizeof(block));
    }
    double b = now_seconds();
    for (unsigned i = 0; i < sizeof(block); ++i) block[i] = (unsigned char)(7 * i);
    for (unsigned i = 0; i < rounds; ++i) {
        block[i % sizeof(block)] = (unsigned char)i;
        uint64_t h = shader_hash(block, sizeof(block));
        hash_sink ^= h; hash_sink ^= h;
    }
    double c = now_seconds();
    printf("model lookup %u calls: old %.6f s, new %.6f s (early keys, no locks)\n", iterations, middle-start, end-middle);
    printf("model hash %u rounds 64 KiB: old %.6f s, new %.6f s\n", rounds, b-a, c-b);
    puts("Model equivalence PASS; no Windows hooks, Wine, GPU or FPS measured.");
    return 0;
}
