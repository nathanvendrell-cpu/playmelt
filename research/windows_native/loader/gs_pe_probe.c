/* Source-generated PE only; GS lives only in this disposable x86_64 child. */
#include "pe_loader.h"
#include "gs_pe_probe.h"
#include "gs_pe_fixture.h"
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/sysctl.h>

#define TEXT 0x4000
#define RDATA 0x8000
#define DATA 0xc000
#define IAT 0x8180
static pm_pe_image image;
static unsigned resolver_calls,checks,callback_failures;
static int reject_import,inject_failure;
static const uint64_t tls_value=UINT64_C(0x12345678abcdef00);
static uint64_t u64(const void *p) { uint64_t v; memcpy(&v,p,8); return v; }
#ifndef PM_GS_PE_HOST_TESTS_ONLY
static uint32_t u32(const void *p) { uint32_t v; memcpy(&v,p,4); return v; }
#endif

static int protection(uintptr_t pointer,size_t length,vm_prot_t expected) {
    mach_vm_address_t address=pointer; mach_vm_size_t size=0;
    vm_region_basic_info_data_64_t info={0}; mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    kern_return_t result=mach_vm_region(mach_task_self(),&address,&size,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object);
    if (object!=MACH_PORT_NULL && mach_port_deallocate(mach_task_self(),object)!=KERN_SUCCESS) return 0;
    return result==KERN_SUCCESS && address<=pointer && pointer-address<=size &&
        length<=size-(pointer-address) && info.protection==expected;
}
static int absent(uintptr_t pointer,size_t length) {
    mach_vm_address_t address=pointer; mach_vm_size_t size=0;
    vm_region_basic_info_data_64_t info={0}; mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    kern_return_t result=mach_vm_region(mach_task_self(),&address,&size,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object);
    if (object!=MACH_PORT_NULL && mach_port_deallocate(mach_task_self(),object)!=KERN_SUCCESS) return 0;
    return result==KERN_INVALID_ADDRESS || (result==KERN_SUCCESS && address>=pointer && address-pointer>=length);
}
static int resolve(void *unused,const char *dll,const char *name,uint16_t ordinal,int by_ordinal,uintptr_t *address) {
    (void)unused; ++resolver_calls; if (!address) return 0; *address=0;
    if (reject_import || ordinal || by_ordinal || !dll || !name || strcmp(dll,"playmelt_fixture.dll") || strcmp(name,"GSCheckpoint")) return 0;
    *address=(uintptr_t)&pm_gs_import_gateway; return 1;
}
static int registers_valid(const pm_gs_context *c) {
    const uint64_t expected[8]={0x1357,0x2468,0x3579,0x468a,(uintptr_t)c,0x579b,0x68ac,0x79bd};
    if (memcmp(c->registers,expected,sizeof expected)) return 0;
    for (unsigned r=0;r<10;++r) for (unsigned b=0;b<16;++b)
        if (c->xmm[r*16+b]!=(uint8_t)(r+6)) return 0;
    return 1;
}
__attribute__((noinline))
static void checkpoint(pm_gs_context *c) {
    int saved_errno=errno; uint64_t words[4]; pm_gs_read_host_words(words);
    int ok=c->callbacks<2 && c->stage==4 && c->stack_aligned==1 &&
        saved_errno==(int)c->errno_value && (uintptr_t)__error()==c->errno_pointer &&
        (uintptr_t)pthread_self()==c->expected_pthread && !memcmp(words,c->host_words,sizeof words) && registers_valid(c);
    thread_identifier_info_data_t info={0}; mach_msg_type_number_t count=THREAD_IDENTIFIER_INFO_COUNT;
    mach_port_t thread=mach_thread_self();
    kern_return_t result=thread_info(thread,THREAD_IDENTIFIER_INFO,(thread_info_t)&info,&count);
    kern_return_t released=mach_port_deallocate(mach_task_self(),thread);
    ok=ok && result==KERN_SUCCESS && released==KERN_SUCCESS && count==THREAD_IDENTIFIER_INFO_COUNT && info.thread_handle==c->host_base;
    ++c->callbacks;
    if (!ok) ++callback_failures;
    if (!ok || inject_failure) c->failure=1;
    errno=saved_errno;
    __asm__ volatile("pcmpeqb %%xmm6,%%xmm6; pcmpeqb %%xmm7,%%xmm7; pcmpeqb %%xmm8,%%xmm8; pcmpeqb %%xmm9,%%xmm9;"
        "pcmpeqb %%xmm10,%%xmm10; pcmpeqb %%xmm11,%%xmm11; pcmpeqb %%xmm12,%%xmm12; pcmpeqb %%xmm13,%%xmm13;"
        "pcmpeqb %%xmm14,%%xmm14; pcmpeqb %%xmm15,%%xmm15; movq $0xdead,%%rdi; movq $0xbeef,%%rsi"
        : : : "xmm6","xmm7","xmm8","xmm9","xmm10","xmm11","xmm12","xmm13","xmm14","xmm15","rdi","rsi");
}

static int mapping_valid(void) {
    if (!image.mapping || image.entrypoint_rva!=TEXT || image.mapping_size!=0x14000 || resolver_calls!=1) return 0;
    const uint8_t *p=image.mapping;
    if (memcmp(p+TEXT,gs_pe_fixture+0x400,0x800) || u64(p+IAT)!=(uintptr_t)&pm_gs_import_gateway ||
        u64(p+IAT+8)!=0 || u64(p+DATA)!=(uintptr_t)p+DATA+8 ||
        u64(p+DATA+8)!=UINT64_C(0x492a6e7c0506cafe)) return 0;
    for (unsigned i=0;i<2;++i) {
        const uint8_t *call=p+gs_pe_callsites[i]; int32_t disp; memcpy(&disp,call+2,4);
        if (call[0]!=0xff || call[1]!=0x15 || (int64_t)gs_pe_callsites[i]+6+disp!=IAT ||
            gs_pe_guards[i]!=gs_pe_callsites[i]+6 || memcmp(p+gs_pe_guards[i],"\x49\x83\x7c\x24\x68\x00\x0f\x85",8)) return 0;
    }
    return protection((uintptr_t)p+TEXT,0x800,VM_PROT_READ|VM_PROT_EXECUTE) &&
        protection((uintptr_t)p+RDATA,0x400,VM_PROT_READ) &&
        protection((uintptr_t)p+DATA,0x200,VM_PROT_READ|VM_PROT_WRITE);
}

static int units(void) {
    int passed=0; char error[200]; uint8_t bad[sizeof gs_pe_fixture];
#define TEST(x) do { ++checks; if (!(x)) { fprintf(stderr,"GS PE host check failed at %d: %s\n",__LINE__,error); goto done; } } while(0)
    error[0]=0; resolver_calls=0;
    TEST(pm_pe_load(gs_pe_fixture,sizeof gs_pe_fixture,resolve,NULL,&image,error,sizeof error));
    TEST(mapping_valid()); uintptr_t base=(uintptr_t)image.mapping; size_t size=image.mapping_size;
    TEST(pm_pe_unload(&image)); TEST(!image.mapping && absent(base,size));
    memcpy(bad,gs_pe_fixture,sizeof bad); uint32_t directory[2]={DATA,40};
    memcpy(bad+0x98+112+9*8,directory,8); resolver_calls=0;
    TEST(!pm_pe_load(bad,sizeof bad,resolve,NULL,&image,error,sizeof error));
    TEST(!image.mapping && !image.lifetime && resolver_calls==0);
    memcpy(bad,gs_pe_fixture,sizeof bad); bad[0xe02]='!'; resolver_calls=0;
    TEST(!pm_pe_load(bad,sizeof bad,resolve,NULL,&image,error,sizeof error)); TEST(!image.mapping && resolver_calls==1);
    memcpy(bad,gs_pe_fixture,sizeof bad); bad[0xc80]='!'; resolver_calls=0;
    TEST(!pm_pe_load(bad,sizeof bad,resolve,NULL,&image,error,sizeof error)); TEST(!image.mapping && resolver_calls==1);
    reject_import=1; resolver_calls=0;
    TEST(!pm_pe_load(gs_pe_fixture,sizeof gs_pe_fixture,resolve,NULL,&image,error,sizeof error)); TEST(!image.mapping && resolver_calls==1); reject_import=0;
    uintptr_t address=1; TEST(!resolve(NULL,"playmelt_fixture.dll","GSCheckpoint",1,1,&address) && !address);
    address=1; TEST(!resolve(NULL,"playmelt_fixture.dll","GSCheckpoint",1,0,&address) && !address);
    passed=1;
done:
    if (!pm_pe_unload(&image)) passed=0;
    printf("{\"kind\":\"host-tests\",\"passed\":%s,\"checks\":%u,\"peExecuted\":false,\"gsChanged\":false}\n",passed?"true":"false",checks);
    return !passed;
#undef TEST
}

#ifndef PM_GS_PE_HOST_TESTS_ONLY
static int prepare(pm_gs_context *c) {
    thread_identifier_info_data_t info={0}; mach_msg_type_number_t count=THREAD_IDENTIFIER_INFO_COUNT;
    mach_port_t thread=mach_thread_self();
    kern_return_t result=thread_info(thread,THREAD_IDENTIFIER_INFO,(thread_info_t)&info,&count);
    kern_return_t released=mach_port_deallocate(mach_task_self(),thread);
    if (result!=KERN_SUCCESS || released!=KERN_SUCCESS || count!=THREAD_IDENTIFIER_INFO_COUNT ||
        !info.thread_handle || (info.thread_handle&7) || info.thread_handle>UINT64_MAX-32) return 0;
    uint64_t words[4]; mach_vm_size_t bytes=0;
    result=mach_vm_read_overwrite(mach_task_self(),info.thread_handle,sizeof words,(mach_vm_address_t)(uintptr_t)words,&bytes);
    if (result!=KERN_SUCCESS || bytes!=sizeof words) return 0;
    pm_gs_read_host_words(c->host_words);
    if (memcmp(words,c->host_words,sizeof words) || words[0]!=(uintptr_t)pthread_self()) return 0;
    c->host_base=info.thread_handle; c->expected_pthread=(uintptr_t)pthread_self();
    c->errno_pointer=(uintptr_t)__error(); c->errno_value=EDOM; c->callback=(uintptr_t)&checkpoint;
    return 1;
}
static int probe(void) {
    char error[200]={0}; int code=1,loaded=0,verified=0,executed=0,restored=0,mask_changed=0;
    pm_gs_pe_context context={0}; pm_gs_context *c=&context.gs; sigset_t mask,old_mask;
    struct rlimit limit={0,0}; if (setrlimit(RLIMIT_CORE,&limit)) return 1;
    if (!prepare(c)) { puts("{\"status\":\"UNSUPPORTED\",\"reason\":\"host-GS-unverified\",\"peExecuted\":false}"); return 77; }
    uint8_t teb[128] __attribute__((aligned(16)))={0}; uint64_t block[2]={tls_value,UINT64_C(0xfeedcab00505cafe)},vector[2]={0,(uintptr_t)block};
    c->guest_base=(uintptr_t)teb; c->tls_vector=(uintptr_t)vector; c->tls_block=(uintptr_t)block;
    memcpy(teb+GS_TEB_SELF,&c->guest_base,8); memcpy(teb+GS_TEB_TLS_VECTOR,&c->tls_vector,8);
    resolver_calls=0;
    loaded=pm_pe_load(gs_pe_fixture,sizeof gs_pe_fixture,resolve,NULL,&image,error,sizeof error);
    if (!loaded || !(verified=mapping_valid())) goto cleanup;
    if (sigfillset(&mask)) goto cleanup;
    const int fatal[]={SIGILL,SIGSEGV,SIGBUS,SIGFPE,SIGABRT,SIGTRAP};
    for (unsigned i=0;i<sizeof fatal/sizeof *fatal;++i) {
        struct sigaction action={0}; action.sa_handler=SIG_DFL;
        if (sigemptyset(&action.sa_mask) || sigaction(fatal[i],&action,NULL) || sigdelset(&mask,fatal[i])) goto cleanup;
    }
    if (pthread_sigmask(SIG_SETMASK,&mask,&old_mask)) goto cleanup;
    mask_changed=1;
    int translated=-1; size_t length=sizeof translated;
    if (sysctlbyname("sysctl.proc_translated",&translated,&length,NULL,0)) translated=-1;
    printf("{\"kind\":\"preflight\",\"mappingEntryIATRelocationVerified\":true,\"machWXVerified\":true,\"rosetta\":%s}\n",translated<0?"null":translated?"true":"false"); fflush(stdout);
    errno=EDOM;
    uint64_t status=pm_gs_invoke_pe(&context,(uintptr_t)image.mapping+image.entrypoint_rva);
    executed=context.entry_calls==1;
    int host_ok=errno==EDOM && (uintptr_t)__error()==c->errno_pointer && (uintptr_t)pthread_self()==c->expected_pthread;
    uint64_t after[4]; pm_gs_read_host_words(after);
    restored=host_ok && c->restored==1 && !memcmp(after,c->host_words,sizeof after);
    int mask_ok=pthread_sigmask(SIG_SETMASK,&old_mask,NULL)==0; mask_changed=0;
    const uint8_t *p=image.mapping; unsigned expected=inject_failure?1:2;
    int marker_ok=u32(p+DATA+0x20)==1 && u32(p+DATA+0x24)==expected &&
        u32(p+DATA+0x28)==(inject_failure?0:2) && u32(p+DATA+0x30)==(inject_failure?0:1) && u32(p+DATA+0x38)==(inject_failure?1:0);
    int passed=verified && executed && restored && mask_ok && !callback_failures && status==(uint64_t)inject_failure &&
        context.entry_result==(uint64_t)inject_failure && c->callbacks==expected && c->reads==expected && c->writes==expected &&
        block[0]==tls_value+expected && block[1]==UINT64_C(0xfeedcab00505cafe) && registers_valid(c) && marker_ok &&
        u32(teb+GS_TEB_LAST_ERROR)==0x76543210;
    code=passed?0:(status==77 && restored && mask_ok?77:1);
    printf("{\"kind\":\"guest-result\",\"passed\":%s,\"expectedCallbackRefusal\":%s,\"entryCalls\":%llu,\"peReturn\":%llu,"
        "\"iatAttempts\":%u,\"iatGuardsPassed\":%u,\"normalMarker\":%u,\"errorMarker\":%u,\"markersVerified\":%s,"
        "\"tlsWrites\":%llu,\"hostCallbacks\":%llu,\"callbackFailures\":%u,\"darwinGSPthreadErrnoRestored\":%s,\"signalMaskRestored\":%s,\"registersVerified\":%s}\n",
        passed?"true":"false",inject_failure?"true":"false",(unsigned long long)context.entry_calls,(unsigned long long)context.entry_result,
        u32(p+DATA+0x24),u32(p+DATA+0x28),u32(p+DATA+0x30),u32(p+DATA+0x38),marker_ok?"true":"false",
        (unsigned long long)c->writes,(unsigned long long)c->callbacks,callback_failures,restored?"true":"false",mask_ok?"true":"false",registers_valid(c)?"true":"false");
cleanup:;
    if (mask_changed && pthread_sigmask(SIG_SETMASK,&old_mask,NULL)) code=1;
    uintptr_t base=(uintptr_t)image.mapping; size_t size=image.mapping_size;
    int unloaded=pm_pe_unload(&image); int removed=unloaded && !image.mapping && (!base || absent(base,size));
    if (!removed) code=1;
    printf("{\"status\":\"%s\",\"peLoaded\":%s,\"peExecuted\":%s,\"resolutions\":%u,\"imageUnloaded\":%s,\"machMappingAbsent\":%s,"
        "\"threadsTested\":1,\"staticTLSLoaderImplemented\":false,\"wineUsed\":false,\"gameExecuted\":false}\n",
        code==0?"PASS":code==77?"UNSUPPORTED":"FAIL",loaded?"true":"false",executed?"true":"false",resolver_calls,unloaded?"true":"false",removed?"true":"false");
    if (code==1 && error[0]) fprintf(stderr,"GS PE probe failed: %s\n",error);
    return code;
}
#endif
int main(int argc,char **argv) {
    if (argc!=2) return 2;
    if (!strcmp(argv[1],"--host-tests")) return units();
#ifdef PM_GS_PE_HOST_TESTS_ONLY
    (void)checkpoint; (void)tls_value; return 2;
#else
    if (!strcmp(argv[1],"--roundtrip")) return probe();
    if (!strcmp(argv[1],"--callback-refusal")) { inject_failure=1; return probe(); }
    return 2;
#endif
}
