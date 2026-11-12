// Independent Windows x64 CPU probe. Compile for baseline x86-64, without AVX.
// CPUID/XGETBV reports do not establish that translated instructions execute.
#include <cpuid.h>
#include <immintrin.h>
#include <cstdint>
#include <cstdio>
#include <cstring>

static bool validNonce(const char *s) {
    if (std::strlen(s) != 36) return false;
    for (int i = 0; i < 36; ++i) {
        const char c = s[i];
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (c != '-') return false; }
        else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
    }
    return true;
}

static uint64_t xgetbv0() {
    uint32_t lo, hi;
    __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    return (uint64_t(hi) << 32) | lo;
}

// Volatile input prevents constant folding; AVX instructions remain in these
// non-inlined, separately targeted functions and are called only after guards.
static volatile int inputAVX2 = 17;
static volatile float inputF16C = 1.5f;
__attribute__((target("avx2"), noinline)) static bool testAVX2() {
    __m256i x = _mm256_set1_epi32(inputAVX2);
    __m256i y = _mm256_add_epi32(x, _mm256_set1_epi32(25));
    alignas(32) int result[8];
    _mm256_storeu_si256(reinterpret_cast<__m256i *>(result), y);
    for (int v : result) if (v != 42) return false;
    return true;
}
__attribute__((target("avx,f16c"), noinline)) static bool testF16C() {
    return _cvtss_sh(inputF16C, 0) == 0x3e00;
}
static const char *jsonBool(bool v) { return v ? "true" : "false"; }

int main(int argc, char **argv) {
    if (argc < 3 || argc > 5 || std::strcmp(argv[1], "--nonce") || !validNonce(argv[2]) ||
        (argc >= 4 && std::strcmp(argv[3], "--execute-tests")) ||
        (argc == 5 && std::strcmp(argv[4], "avx2") && std::strcmp(argv[4], "f16c"))) return 64;
    const bool execute = argc >= 4;
    const bool runAVX2 = execute && (argc == 4 || !std::strcmp(argv[4], "avx2"));
    const bool runF16C = execute && (argc == 4 || !std::strcmp(argv[4], "f16c"));
    unsigned a = 0, b = 0, c = 0, d = 0;
    const unsigned maxLeaf = __get_cpuid_max(0, nullptr);
    bool avx = false, avx2 = false, f16c = false, xsave = false, osxsave = false;
    if (maxLeaf >= 1) {
        __cpuid_count(1, 0, a, b, c, d);
        avx = (c & (1u << 28)) != 0;
        f16c = (c & (1u << 29)) != 0;
        xsave = (c & (1u << 26)) != 0;
        osxsave = (c & (1u << 27)) != 0;
    }
    if (maxLeaf >= 7) { __cpuid_count(7, 0, a, b, c, d); avx2 = (b & (1u << 5)) != 0; }
    const bool xcr0Read = xsave && osxsave;
    const uint64_t xcr0 = xcr0Read ? xgetbv0() : 0;
    const bool avxState = avx && xcr0Read && (xcr0 & 6) == 6;
    const bool avx2Usable = avxState && avx2, f16cUsable = avxState && f16c;
    const char *avx2Result = "not_run", *f16cResult = "not_run";
    if (runAVX2) avx2Result = avx2Usable ? (testAVX2() ? "passed" : "failed") : "unavailable";
    if (runF16C) f16cResult = f16cUsable ? (testF16C() ? "passed" : "failed") : "unavailable";
    std::printf("{\"schema\":1,\"kind\":\"playmelt-cpu-probe\",\"nonce\":\"%s\","
                "\"cpuid\":{\"maxBasicLeaf\":%u,\"avx\":%s,\"avx2\":%s,\"f16c\":%s,\"xsave\":%s,\"osxsave\":%s},"
                "\"xcr0Read\":%s,\"xcr0\":%llu,\"avx2UsableAccordingToBitsAndOS\":%s,\"f16cUsableAccordingToBitsAndOS\":%s,"
                "\"executionRequested\":%s,\"avx2Execution\":\"%s\",\"f16cExecution\":\"%s\"}\n",
                argv[2], maxLeaf, jsonBool(avx), jsonBool(avx2), jsonBool(f16c), jsonBool(xsave), jsonBool(osxsave),
                jsonBool(xcr0Read), static_cast<unsigned long long>(xcr0), jsonBool(avx2Usable), jsonBool(f16cUsable),
                jsonBool(execute), avx2Result, f16cResult);
    return (runAVX2 && std::strcmp(avx2Result, "passed")) ||
           (runF16C && std::strcmp(f16cResult, "passed")) ? 1 : 0;
}
