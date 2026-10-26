/* Disposable child ONLY; no PE/file input or TLS loader. See GS_PROBE.md. */
#include "gs_probe.h"
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <unistd.h>

#if !defined(__APPLE__) || !defined(__x86_64__)
#error "GS research host requires Darwin x86_64"
#endif
static const uint64_t tls_sentinel=UINT64_C(0x12345678abcdef00);
static unsigned checks;
static int host_matches(uint64_t base,const uint64_t direct[4],const uint64_t copied[4],uintptr_t self) {
    return base && !(base&7) && base<=UINT64_MAX-32 && self &&
        direct[0]==self && memcmp(direct,copied,32)==0;
}

#ifndef PM_GS_HOST_TESTS_ONLY
/* Apple tests/ldt.c uses THREAD_IDENTIFIER_INFO.thread_handle. Do not guess
 * a pthread struct offset or dereference the returned address unchecked. */
static int preflight(pm_gs_context *context) {
    thread_identifier_info_data_t info={0};
    mach_msg_type_number_t count=THREAD_IDENTIFIER_INFO_COUNT;
    mach_port_t thread=mach_thread_self();
    kern_return_t status=thread_info(thread,THREAD_IDENTIFIER_INFO,(thread_info_t)&info,&count);
    kern_return_t released=mach_port_deallocate(mach_task_self(),thread);
    if (status!=KERN_SUCCESS || released!=KERN_SUCCESS || count!=THREAD_IDENTIFIER_INFO_COUNT ||
        !info.thread_handle || info.thread_handle>UINT64_MAX-32) return 0;
    uint64_t words[4]={0}; mach_vm_size_t bytes=0;
    status=mach_vm_read_overwrite(mach_task_self(),info.thread_handle,sizeof words,
                                  (mach_vm_address_t)(uintptr_t)words,&bytes);
    if (status!=KERN_SUCCESS || bytes!=sizeof words) return 0;
    pm_gs_read_host_words(context->host_words);
    if (!host_matches(info.thread_handle,context->host_words,words,(uintptr_t)pthread_self())) return 0;
    context->host_base=info.thread_handle;
    context->expected_pthread=(uintptr_t)pthread_self();
    context->errno_pointer=(uintptr_t)__error(); context->errno_value=EDOM;
    return 1;
}
#endif

static int check_registers(const pm_gs_context *context) {
    const uint64_t expected[8]={0x1357,0x2468,0x3579,0x468a,(uintptr_t)context,0x579b,0x68ac,0x79bd};
    if (memcmp(context->registers,expected,sizeof expected)) return 0;
    for (unsigned reg=0;reg<10;++reg)
        for (unsigned byte=0;byte<16;++byte)
            if (context->xmm[reg*16+byte]!=(uint8_t)(reg+6)) return 0;
    return 1;
}

/* Assembly checks FOUR restored Darwin GS slots before this SysV function.
 * Deliberately clobber the larger Win64 nonvolatile vector set and RDI/RSI. */
__attribute__((noinline))
static void host_checkpoint(pm_gs_context *context) {
    int incoming_errno=errno; uint64_t words[4]={0};
    pm_gs_read_host_words(words);
    int valid=context->callbacks<2 && context->stage==4 && context->stack_aligned==1 &&
        (uintptr_t)pthread_self()==context->expected_pthread &&
        (uintptr_t)__error()==context->errno_pointer && incoming_errno==(int)context->errno_value &&
        memcmp(words,context->host_words,sizeof words)==0 && check_registers(context);
    thread_identifier_info_data_t info={0};
    mach_msg_type_number_t count=THREAD_IDENTIFIER_INFO_COUNT;
    mach_port_t thread=mach_thread_self();
    kern_return_t result=thread_info(thread,THREAD_IDENTIFIER_INFO,(thread_info_t)&info,&count);
    kern_return_t released=mach_port_deallocate(mach_task_self(),thread);
    valid=valid && result==KERN_SUCCESS && released==KERN_SUCCESS &&
        count==THREAD_IDENTIFIER_INFO_COUNT && info.thread_handle==context->host_base;
    ++context->callbacks; if (!valid) context->failure=1;
    errno=incoming_errno;
    __asm__ volatile(
        "pcmpeqb %%xmm6,%%xmm6\n\tpcmpeqb %%xmm7,%%xmm7\n\t"
        "pcmpeqb %%xmm8,%%xmm8\n\tpcmpeqb %%xmm9,%%xmm9\n\t"
        "pcmpeqb %%xmm10,%%xmm10\n\tpcmpeqb %%xmm11,%%xmm11\n\t"
        "pcmpeqb %%xmm12,%%xmm12\n\tpcmpeqb %%xmm13,%%xmm13\n\t"
        "pcmpeqb %%xmm14,%%xmm14\n\tpcmpeqb %%xmm15,%%xmm15\n\t"
        "movq $0xdead,%%rdi\n\tmovq $0xbeef,%%rsi"
        : : : "xmm6","xmm7","xmm8","xmm9","xmm10","xmm11","xmm12","xmm13","xmm14","xmm15","rdi","rsi");
}

static void initialize_guest(pm_gs_context *context,uint8_t teb[128],uint64_t vector[2],uint64_t block[2]) {
    memset(teb,0,128); vector[0]=0; vector[1]=(uintptr_t)block;
    block[0]=tls_sentinel; block[1]=UINT64_C(0xfeedcab00505cafe);
    context->guest_base=(uintptr_t)teb; context->tls_vector=(uintptr_t)vector; context->tls_block=(uintptr_t)block;
    context->import_entry=(uintptr_t)&pm_gs_import_gateway; context->callback=(uintptr_t)&host_checkpoint;
    memcpy(teb+GS_TEB_SELF,&context->guest_base,8); memcpy(teb+GS_TEB_TLS_VECTOR,&context->tls_vector,8);
}

static int unit_tests(void) {
    uint64_t direct[4]={0x100,2,3,4}, copied[4]={0x100,2,3,4};
#define TEST(x) do { ++checks; if (!(x)) { fprintf(stderr,"GS host test failed at line %d\n",__LINE__); return 1; } } while(0)
    TEST(host_matches(0x1000,direct,copied,0x100));
    TEST(!host_matches(0,direct,copied,0x100)); TEST(!host_matches(0x1001,direct,copied,0x100));
    TEST(!host_matches(UINT64_MAX-7,direct,copied,0x100)); TEST(!host_matches(0x1000,direct,copied,0));
    TEST(!host_matches(0x1000,direct,copied,0x200));
    for (unsigned i=0;i<4;++i) { copied[i]^=1; TEST(!host_matches(0x1000,direct,copied,0x100)); copied[i]^=1; }
    pm_gs_context context={0}; uint8_t teb[128]; uint64_t vector[2],block[2],value;
    initialize_guest(&context,teb,vector,block);
    memcpy(&value,teb+GS_TEB_SELF,8); TEST(value==(uintptr_t)teb);
    memcpy(&value,teb+GS_TEB_TLS_VECTOR,8); TEST(value==(uintptr_t)vector);
    TEST(vector[1]==(uintptr_t)block && vector[0]==0 && block[0]==tls_sentinel); TEST(!check_registers(&context));
    const uint64_t regs[8]={0x1357,0x2468,0x3579,0x468a,(uintptr_t)&context,0x579b,0x68ac,0x79bd};
    memcpy(context.registers,regs,sizeof regs);
    for (unsigned r=0;r<10;++r) memset(context.xmm+r*16,(int)r+6,16);
    TEST(check_registers(&context));
    for (unsigned r=0;r<8;++r) { context.registers[r]^=1; TEST(!check_registers(&context)); context.registers[r]^=1; }
    for (unsigned b=0;b<sizeof context.xmm;++b) { context.xmm[b]^=1; TEST(!check_registers(&context)); context.xmm[b]^=1; }
    TEST(check_registers(&context));
    printf("{\"kind\":\"host-tests\",\"passed\":true,\"checks\":%u,\"gsChanged\":false}\n",checks);
    return 0;
#undef TEST
}

int main(int argc,char **argv) {
    if (argc!=2) return 2;
    if (!strcmp(argv[1],"--host-tests")) return unit_tests();
#ifdef PM_GS_HOST_TESTS_ONLY
    return 2; /* Instrumented build never invokes the switching assembly. */
#else
    if (strcmp(argv[1],"--roundtrip") && strcmp(argv[1],"--force-unavailable") &&
        strcmp(argv[1],"--force-sigill") && strcmp(argv[1],"--force-timeout")) return 2;
    struct rlimit limit={0,0}; if (setrlimit(RLIMIT_CORE,&limit)) return 2;
    if (!strcmp(argv[1],"--force-unavailable")) {
        puts("{\"status\":\"UNSUPPORTED\",\"reason\":\"negative-control-unavailable\",\"gsChanged\":false}"); return 77;
    }
    if (!strcmp(argv[1],"--force-sigill")) { __asm__ volatile("ud2"); return 1; }
    if (!strcmp(argv[1],"--force-timeout")) { for (;;) pause(); }
    pm_gs_context context={0};
    if (!preflight(&context)) {
        puts("{\"status\":\"UNSUPPORTED\",\"reason\":\"Darwin-TSD-base-not-verified\",\"gsChanged\":false}"); return 77;
    }
    int translated=-1; size_t length=sizeof translated;
    if (sysctlbyname("sysctl.proc_translated",&translated,&length,NULL,0)) translated=-1;
    uint8_t teb[128] __attribute__((aligned(16))); uint64_t vector[2],block[2];
    initialize_guest(&context,teb,vector,block);
    sigset_t mask,old_mask; if (sigfillset(&mask)) return 2;
    const int fatal[]={SIGILL,SIGSEGV,SIGBUS,SIGFPE,SIGABRT,SIGTRAP};
    for (unsigned i=0;i<sizeof fatal/sizeof *fatal;++i) {
        struct sigaction action={0}; action.sa_handler=SIG_DFL;
        if (sigemptyset(&action.sa_mask) || sigaction(fatal[i],&action,NULL) || sigdelset(&mask,fatal[i])) return 2;
    }
    if (pthread_sigmask(SIG_SETMASK,&mask,&old_mask)) return 2;
    printf("{\"kind\":\"preflight\",\"threadHandleMatchesActualGS\":true,\"rosetta\":%s,\"threadsTested\":1}\n",translated<0?"null":translated==1?"true":"false");
    fflush(stdout); errno=(int)context.errno_value;
    uint64_t status=pm_gs_roundtrip(&context);
    /* Return is possible only after assembly checked Darwin GS restoration. */
    int errno_ok=errno==(int)context.errno_value && (uintptr_t)__error()==context.errno_pointer;
    int pthread_ok=(uintptr_t)pthread_self()==context.expected_pthread;
    uint64_t after[4]; pm_gs_read_host_words(after);
    int restored=context.restored==1 && !memcmp(after,context.host_words,sizeof after);
    int mask_ok=pthread_sigmask(SIG_SETMASK,&old_mask,NULL)==0;
    uint32_t guest_last_error=0; memcpy(&guest_last_error,teb+GS_TEB_LAST_ERROR,4);
    int passed=!status && context.callbacks==2 && context.reads==2 && context.writes==2 &&
        block[0]==tls_sentinel+2 && block[1]==UINT64_C(0xfeedcab00505cafe) &&
        guest_last_error==0x76543210 && errno_ok && pthread_ok && restored && mask_ok && check_registers(&context);
    int safely_unsupported=status==77 && errno_ok && pthread_ok && restored && mask_ok;
    printf("{\"status\":\"%s\",\"passed\":%s,\"gsActuallyRead\":%s,\"tlsWrites\":%llu,"
        "\"hostCallbacks\":%llu,\"darwinGSRestored\":%s,\"pthreadSelfPreserved\":%s,\"errnoPreserved\":%s,"
        "\"nonvolatileGPRs\":8,\"nonvolatileXMMRegisters\":10,\"registersVerified\":%s,"
        "\"signalMaskRestored\":%s,\"stage\":%llu,\"setterReturn\":%llu,\"setterCarry\":%llu,"
        "\"threadsTested\":1,\"peLoaded\":false,\"staticTLSLoaderImplemented\":false,\"wineUsed\":false,\"gameExecuted\":false}\n",
        passed?"PASS":safely_unsupported?"UNSUPPORTED":"FAIL",passed?"true":"false",context.reads?"true":"false",
        (unsigned long long)context.writes,(unsigned long long)context.callbacks,restored?"true":"false",
        pthread_ok?"true":"false",errno_ok?"true":"false",check_registers(&context)?"true":"false",
        mask_ok?"true":"false",(unsigned long long)context.stage,(unsigned long long)context.set_result,(unsigned long long)context.set_carry);
    return passed?0:safely_unsupported?77:1;
#endif
}
