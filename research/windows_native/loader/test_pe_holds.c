/* Private fault-injection controls; no PE entry/import function is executed. */
#define main loader_regression_not_invoked
#include "test_pe_loader.c"
#undef main

static void load_exe(pm_pe_image *image) {
    fixture f=make_fixture(); resolver_state state={0}; char error[192];
    CHECK(pm_pe_load(f.bytes,sizeof f.bytes,resolve,&state,image,error,sizeof error));
    CHECK(image->lifetime && image->lifetime->ready && !image->lifetime->is_dll);
}
static void load_dll(pm_pe_image *image) {
    fixture f=make_dll_fixture(); char error[192];
    CHECK(pm_pe_load(f.bytes,sizeof f.bytes,NULL,NULL,image,error,sizeof error));
    CHECK(image->lifetime && image->lifetime->ready && image->lifetime->is_dll);
}
static int hold(pm_pe_image *client,const pm_pe_image *const *deps,size_t n) {
    char error[192]; return pm_pe_hold_dependencies(client,deps,n,error,sizeof error);
}
static void test_lists_and_refs(void) {
    reset_tracking(); pm_pe_image a={0},b={0},dll={0},other={0};
    load_exe(&a); load_exe(&b); load_dll(&dll); load_dll(&other);
    const pm_pe_image *one[]={&dll},*two[]={&dll,&other},*bad[]={&dll,&b},*duplicate[]={&dll,&dll};
    CHECK(!hold(NULL,one,1)); CHECK(!hold(&a,NULL,1)); CHECK(!hold(&a,one,0)); CHECK(!hold(&a,one,33));
    CHECK(!hold(&a,bad,2)); CHECK(!dll.lifetime->incoming && !a.lifetime->declared);
    CHECK(!hold(&a,duplicate,2)); CHECK(!dll.lifetime->incoming && !a.lifetime->declared);
    const pm_pe_image *self[]={&a}; CHECK(!hold(&a,self,1)); CHECK(!hold(&dll,one,1));
    pm_pe_image copy=dll; const pm_pe_image *copied[]={&copy}; CHECK(!hold(&a,copied,1));
    CHECK(!pm_pe_unload(&copy));
    copy=a; CHECK(!hold(&copy,one,1)); CHECK(!pm_pe_unload(&copy));
    void *saved=dll.mapping; dll.mapping=(void *)1; CHECK(!hold(&a,one,1)); dll.mapping=saved;
    dll.lifetime->incoming=PM_PE_CLIENT_HOLD_LIMIT; CHECK(!hold(&a,one,1));
    CHECK(dll.lifetime->incoming==PM_PE_CLIENT_HOLD_LIMIT && !a.lifetime->declared); dll.lifetime->incoming=0;
    CHECK(hold(&a,two,2)); CHECK(hold(&b,one,1));
    CHECK(dll.lifetime->incoming==2 && other.lifetime->incoming==1);
    CHECK(!hold(&a,one,1)); CHECK(a.lifetime->dependency_count==2 && dll.lifetime->incoming==2);
    unsigned unmapped=unmap_calls; CHECK(!pm_pe_unload(&dll)); CHECK(!pm_pe_unload(&other)); CHECK(unmap_calls==unmapped);
    /* Corrupt a private fixture counter to prove validation precedes munmap. */
    dll.lifetime->incoming=0; CHECK(!pm_pe_unload(&a)); CHECK(unmap_calls==unmapped);
    dll.lifetime->incoming=2;
    fail_unmapping=1; CHECK(!pm_pe_unload(&a)); CHECK(!a.lifetime->ready);
    CHECK(dll.lifetime->incoming==2 && other.lifetime->incoming==1 && a.mapping);
    CHECK(!hold(&a,one,1));
    fail_unmapping=0; CHECK(pm_pe_unload(&a)); CHECK(!a.lifetime && !a.mapping);
    CHECK(dll.lifetime->incoming==1 && other.lifetime->incoming==0);
    CHECK(pm_pe_unload(&a)); CHECK(dll.lifetime->incoming==1); /* double empty-unload no decrement */
    CHECK(pm_pe_unload(&other)); unmapped=unmap_calls; CHECK(!pm_pe_unload(&dll)); CHECK(unmap_calls==unmapped);
    CHECK(pm_pe_unload(&b)); CHECK(!dll.lifetime->incoming); CHECK(pm_pe_unload(&dll));
    CHECK(!live_mappings && !live_allocations);
}
static void test_capacity_and_cleanup_only(void) {
    reset_tracking(); pm_pe_image client={0},dlls[32]={0}; const pm_pe_image *deps[32];
    load_exe(&client);
    for (size_t i=0;i<32;++i) { load_dll(&dlls[i]); deps[i]=&dlls[i]; }
    CHECK(hold(&client,deps,32));
    for (size_t i=0;i<32;++i) CHECK(dlls[i].lifetime->incoming==1);
    CHECK(pm_pe_unload(&client)); for (size_t i=0;i<32;++i) CHECK(pm_pe_unload(&dlls[i]));
    reset_tracking(); fixture f=make_fixture(); resolver_state state={0}; char error[192];
    fail_allocation_at=2; /* permissions first, then new lifetime; no exports */
    CHECK(!pm_pe_load(f.bytes,sizeof f.bytes,resolve,&state,&client,error,sizeof error));
    CHECK(strstr(error,"lifetime") && !map_calls && !live_allocations);
    reset_tracking(); load_dll(&dlls[0]);
    fail_protection_at=(int)protect_calls+1; fail_unmapping=1;
    CHECK(!pm_pe_load(f.bytes,sizeof f.bytes,resolve,&state,&client,error,sizeof error));
    CHECK(client.lifetime && !client.lifetime->ready && strstr(error,"cleanup-failed"));
    CHECK(!hold(&client,deps,1)); CHECK(!dlls[0].lifetime->incoming);
    fail_protection_at=fail_unmapping=0; CHECK(pm_pe_unload(&client)); CHECK(pm_pe_unload(&dlls[0]));
    reset_tracking(); load_exe(&client); load_dll(&dlls[0]);
    fail_unmapping=1; CHECK(!pm_pe_unload(&dlls[0])); CHECK(!hold(&client,deps,1));
    CHECK(!client.lifetime->declared && !dlls[0].lifetime->incoming);
    fail_unmapping=0; CHECK(pm_pe_unload(&dlls[0])); CHECK(pm_pe_unload(&client));
}
static void test_synthetic_states_inert(void) {
    reset_tracking(); pm_pe_image client={0},dll={0}; load_exe(&client);
    fixture f=make_fixture(); w16(f.bytes+0x96,0x2022); char error[192]; resolver_state state={0};
    CHECK(pm_pe_load_synthetic_dll(f.bytes,sizeof f.bytes,resolve,&state,&dll,error,sizeof error));
    const pm_pe_image *deps[]={&dll};
    const pm_pe_dll_state states[]={PM_PE_DLL_READY,PM_PE_DLL_ATTACHING,PM_PE_DLL_DETACHING,PM_PE_DLL_DETACHED,PM_PE_DLL_FAILED};
    for (size_t i=0;i<sizeof states/sizeof *states;++i) {
        dll.synthetic_dll->state=states[i]; CHECK(!hold(&client,deps,1));
        CHECK(!client.lifetime->declared && !dll.lifetime->incoming);
    }
    /* State mutation is a test double only. No entry point is called here. */
    dll.synthetic_dll->state=PM_PE_DLL_ATTACHED; CHECK(hold(&client,deps,1));
    unsigned unmapped=unmap_calls;
    CHECK(!pm_pe_synthetic_dll_detach(&dll,error,sizeof error)); CHECK(strstr(error,"dll-held"));
    CHECK(!pm_pe_synthetic_dll_attach(&dll,error,sizeof error));
    CHECK(!pm_pe_unload(&dll) && unmap_calls==unmapped);
    CHECK(pm_pe_unload(&client)); dll.synthetic_dll->state=PM_PE_DLL_DETACHED;
    CHECK(pm_pe_unload(&dll));
}
typedef struct { pm_pe_image *client,*dll; int checked; } thread_attempt;
static void *foreign_thread(void *raw) {
    thread_attempt *a=raw; const pm_pe_image *deps[]={a->dll}; pm_pe_export found; char error[192];
    a->checked=!hold(a->client,deps,1) && !pm_pe_unload(a->client) && !pm_pe_unload(a->dll) &&
        pm_pe_find_export(a->dll,"Alpha",0,0,&found,error,sizeof error);
    return NULL;
}
static void test_thread(void) {
    reset_tracking(); pm_pe_image client={0},dll={0}; load_exe(&client); load_dll(&dll);
    thread_attempt a={&client,&dll,0}; pthread_t thread;
    CHECK(pthread_create(&thread,NULL,foreign_thread,&a)==0); CHECK(pthread_join(thread,NULL)==0); CHECK(a.checked);
    CHECK(!client.lifetime->declared && !dll.lifetime->incoming);
    CHECK(pm_pe_unload(&client)); CHECK(pm_pe_unload(&dll));
}
int main(void) {
    test_lists_and_refs(); test_capacity_and_cleanup_only(); test_synthetic_states_inert(); test_thread();
    CHECK(!live_mappings && !live_allocations && !wx_requests);
    printf("PASS: %u EXE dependency hold checks; fault injection, no guest execution, mappings=0 controls=0\n",checks);
    return 0;
}
