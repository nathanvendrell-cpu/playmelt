/* Embedded synthetic PE only. Copies and compares contexts, never resumes them. */
#include "pe_loader.h"
#include "x64_unwind.h"
#include "unwind_fixture.h"
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>

#if !defined(__APPLE__) || !defined(__x86_64__)
#error "Synthetic unwind checkpoint requires macOS x86_64 Microsoft ABI"
#endif
#define MS_ABI __attribute__((ms_abi))
typedef uint32_t (MS_ABI *entry_function)(void);

/* This single indirect call targets generated machine code without Clang's
 * function-type metadata. All other host code retains UBSan function checks;
 * address/other undefined-behaviour instrumentation stays enabled here too. */
__attribute__((no_sanitize("function")))
static uint32_t call_embedded_fixture(entry_function entry) { return entry(); }

static pm_pe_image loaded;
static uint8_t flat_image[0x14000];
static unsigned checkpoints, failures, registers_verified;
static int64_t largest_snapshot;
static char last_error[160];
static uint64_t u64(const void *p) { uint64_t n; memcpy(&n,p,sizeof n); return n; }

static int32_t MS_ABI checkpoint(const pm_x64_context *snapshot) {
    unsigned index=checkpoints++;
    int ok=0;
    if (index>=2 || !loaded.mapping ||
        snapshot!=(const pm_x64_context *)((const uint8_t *)loaded.mapping+0xC060)) goto done;
    pm_x64_context captured; memcpy(&captured,snapshot,sizeof captured);
    const uint8_t *data=(const uint8_t *)loaded.mapping+0xC000;
    uint64_t caller_rsp=u64(data+0x20), caller_rip=u64(data+0x28);
    uint64_t base=(uintptr_t)loaded.mapping;
    if (caller_rip!=base+expected_returns[index] || captured.rip!=base+capture_rvas[index] ||
        captured.gpr[0]!=captured.rip || captured.gpr[3]!=UINT64_C(0xaabbccddeeff0011) ||
        captured.gpr[12]!=UINT64_C(0x1020304050607080)) goto done;
    /* Check real bounds of the CURRENT pthread before copying this known
     * fixture's live frame. No generic reader of other threads/user binaries. */
    uintptr_t top=(uintptr_t)pthread_get_stackaddr_np(pthread_self());
    size_t stack_size=pthread_get_stacksize_np(pthread_self());
    if (!stack_size || top<stack_size || captured.gpr[4]<top-stack_size ||
        caller_rsp>top || caller_rsp<captured.gpr[4] || caller_rsp-captured.gpr[4]>512 ||
        caller_rsp-captured.gpr[4]<8) goto done;
    size_t bytes=(size_t)(caller_rsp-captured.gpr[4]);
    uint8_t stack_copy[512];
    /* The callback may already have reused the caller's 32-byte shadow space.
     * This is not an atomic snapshot at the marker. Only saved nonvolatiles
     * and the return address above that space are read by this proof. */
    memcpy(stack_copy,(const void *)(uintptr_t)captured.gpr[4],bytes);
    pm_unwind_stack stack={stack_copy,bytes,captured.gpr[4]};
    pm_unwind_image image={flat_image,sizeof flat_image,base,function_table,
        sizeof function_table/sizeof *function_table,1,0};
    pm_x64_context output;
    pm_unwind_result proof;
    if (!pm_x64_unwind_one(&image,&stack,&captured,&output,&proof,last_error,sizeof last_error)) goto done;
    if (proof.phase!=PM_UNWIND_BODY || proof.operations_applied!=3 || proof.stack_words_read!=3 ||
        proof.restored_nonvolatile_mask!=((1u<<3)|(1u<<12)) || proof.stack_advance!=bytes ||
        output.gpr[4]!=caller_rsp || output.rip!=caller_rip ||
        output.gpr[3]!=RBX_SENTINEL || output.gpr[12]!=R12_SENTINEL) goto done;
    for (unsigned reg=0;reg<16;++reg) {
        if (reg==3 || reg==4 || reg==12) continue;
        if (output.gpr[reg]!=captured.gpr[reg]) goto done;
    }
    /* output is only compared. There is no function-pointer cast of its RIP,
     * setcontext/longjmp, saved-stack substitution or exception continuation. */
    registers_verified+=2;
    if ((int64_t)bytes>largest_snapshot) largest_snapshot=(int64_t)bytes;
    ok=1;
done:
    if (!ok) ++failures;
    return ok;
}

static int resolve(void *context,const char *dll,const char *name,
    uint16_t ordinal,int by_ordinal,uintptr_t *address) {
    (void)context;
    if (!address) return 0;
    *address=0;
    if (by_ordinal || ordinal || !dll || !name || strcmp(dll,"playmelt_fixture.dll") ||
        strcmp(name,"UnwindCheckpoint")) return 0;
    *address=(uintptr_t)&checkpoint;
    return 1;
}

int main(int argc,char **argv) {
    if (argc!=2 || strcmp(argv[1],"--synthetic-unwind-test")) return 2;
    int passed=0,executed=0,iat_verified=0;
    if (!pm_pe_load(unwind_fixture,sizeof unwind_fixture,resolve,NULL,&loaded,last_error,sizeof last_error)) goto cleanup;
    if (loaded.mapping_size!=sizeof flat_image) goto cleanup;
    /* Construct a readable RVA projection from ONLY known readable fixture
     * sections. Sparse mapping gaps are never dereferenced by the unwinder. */
    memcpy(flat_image+0x4000,(const uint8_t *)loaded.mapping+0x4000,0x200);
    memcpy(flat_image+0x8000,(const uint8_t *)loaded.mapping+0x8000,0x400);
    iat_verified=u64((const uint8_t *)loaded.mapping+0x8180)==(uintptr_t)&checkpoint;
    if (!iat_verified) goto cleanup;
    entry_function entry=(entry_function)((uint8_t *)loaded.mapping+loaded.entrypoint_rva);
    uint32_t status=call_embedded_fixture(entry); executed=1;
    passed=status==1 && checkpoints==2 && failures==0 && registers_verified==4;
cleanup:;
    int unmapped=pm_pe_unload(&loaded);
    int cleaned=unmapped && !loaded.mapping;
    passed=passed && cleaned;
    int translated=-1; size_t size=sizeof translated;
    if (sysctlbyname("sysctl.proc_translated",&translated,&size,NULL,0)) translated=-1;
    if (!passed) fprintf(stderr,"Synthetic context proof failed: %s\n",last_error);
    printf("{\"schemaVersion\":1,\"passed\":%s,\"syntheticPEExecuted\":%s,"
        "\"checkpointIATVerified\":%s,\"capturedFrames\":%u,\"restoredNonvolatileChecks\":%u,"
        "\"failures\":%u,\"maxStackSnapshotBytes\":%lld,\"cleanupVerified\":%s,"
        "\"rosettaTranslated\":%s,\"rosettaStateKnown\":%s,\"restoredPCExecuted\":false,"
        "\"exceptionDispatched\":false,\"fullContextRestored\":false,\"gameExecuted\":false,"
        "\"wineUsed\":false,\"gpuWorkSubmitted\":false,\"supportDetermined\":false}\n",
        passed?"true":"false",executed?"true":"false",iat_verified?"true":"false",checkpoints,
        registers_verified,failures,(long long)largest_snapshot,cleaned?"true":"false",
        translated==1?"true":"false",translated>=0?"true":"false");
    return passed?0:1;
}
