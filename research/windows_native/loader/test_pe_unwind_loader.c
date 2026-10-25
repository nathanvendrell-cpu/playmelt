/* Reuse exact loader OS/allocation doubles, but run only the new opt-in tests.
 * Separate runner also executes the unchanged original regression main. */
#define main pm_original_loader_regression_main
#include "test_pe_loader.c"
#undef main

static fixture unwind_fixture(void) {
    fixture f=make_fixture();
    directory(&f,3,0x8400,36);
    for (unsigned i=0;i<3;++i) {
        w32(f.bytes+0xa00+12*i,0x4000+16*i);
        w32(f.bytes+0xa04+12*i,0x4010+16*i);
        w32(f.bytes+0xa08+12*i,0x8430+16*i);
        const uint8_t record[]={1,7,3,0,7,0x42,3,0xc0,1,0x30,0,0};
        memcpy(f.bytes+0xa30+16*i,record,sizeof record);
    }
    return f;
}
static void reject_unwind(fixture *f,const char *expected,int premap,unsigned resolver_calls) {
    reset_tracking(); pm_pe_image image={0}; char error[192]; resolver_state state={0};
    fixture original=*f;
    CHECK(!pm_pe_load_synthetic_unwind_exe(f->bytes,sizeof f->bytes,resolve,&state,1,&image,error,sizeof error));
    CHECK(strstr(error,expected));
    CHECK(!image.mapping && !image.synthetic_unwind && !image.synthetic_dll && !image.exports);
    CHECK(!live_mappings && !live_allocations && !wx_requests);
    CHECK(state.calls==resolver_calls && (premap?!map_calls:map_calls==1));
    CHECK(!memcmp(f,&original,sizeof *f));
}
static void test_unwind_refusals(void) {
    fixture good=unwind_fixture(),f;
    for (int attested=-1;attested<=2;++attested) if (attested!=1) {
        reset_tracking(); pm_pe_image image={0}; char error[192]; resolver_state state={0};
        CHECK(!pm_pe_load_synthetic_unwind_exe(good.bytes,sizeof good.bytes,resolve,&state,attested,&image,error,sizeof error));
        CHECK(strstr(error,"attestation") && !map_calls && !state.calls && !allocation_calls && !image.mapping);
    }
    /* Default + DLL opt-in keep directory3 disabled, even for valid V1 bytes. */
    f=good; reject_fixture(&f,"exception/unwind");
    w16(f.bytes+0x96,0x2022); reject_synthetic(&f,"exception/unwind");
    reject_unwind(&f,"EXE",1,0);
    f=good; directory(&f,3,0,0); reject_unwind(&f,"directory 3",1,0);
    f=good; directory(&f,3,0x8401,36); reject_unwind(&f,"12-byte",1,0);
    f=good; directory(&f,3,0x8400,35); reject_unwind(&f,"12-byte",1,0);
    f=good; directory(&f,3,0x8400,12*(PM_UNWIND_MAX_FUNCTIONS+1)); reject_unwind(&f,"directory",1,0);
    f=good; w32(f.bytes+OPT+56,0x104000); reject_unwind(&f,"1 MiB",1,0);
    f=good; w32(f.bytes+0xa00,0x4010); reject_unwind(&f,"function-table",1,0);
    f=good; w32(f.bytes+0xa04,0x4000); reject_unwind(&f,"function-table",1,0);
    f=good; w32(f.bytes+0xa0c,0x4001); reject_unwind(&f,"function-table",1,0);
    f=good; w32(f.bytes+0xa1c,0x14001); reject_unwind(&f,"function-table",1,0);
    f=good; w32(f.bytes+0xa28-8,0x1); reject_unwind(&f,"unwind-rva",1,0);
    f=good; w32(f.bytes+0xa08,0x8431); reject_unwind(&f,"unwind-rva",1,0);
    f=good; f.bytes[0xa50]=2; reject_unwind(&f,"version",1,0);
    for (unsigned flag=1;flag<=31;++flag) {
        f=good; f.bytes[0xa50]=(uint8_t)(1|(flag<<3)); reject_unwind(&f,"flags",1,0);
    }
    f=good; f.bytes[0xa53]=1; reject_unwind(&f,"frame-register",1,0);
    f=good; f.bytes[0xa55]=4; reject_unwind(&f,"opcode",1,0);
    f=good; f.bytes[0xa54]=0; reject_unwind(&f,"offset",1,0);
    f=good; f.bytes[0xa52]=65; reject_unwind(&f,"count",1,0);
    f=good; w32(f.bytes+OPT+16,0x4040); reject_unwind(&f,"entry is not catalogued",1,0);
    f=good; w32(f.bytes+SECTIONS+40+36,0xc0000040); reject_unwind(&f,"unwind-section",1,0);
    f=good; w32(f.bytes+SECTIONS+40+36,0x60000040); reject_unwind(&f,"unwind-section",1,0);
    f=good; w32(f.bytes+SECTIONS+40+36,0x40); reject_unwind(&f,"unwind-section",1,0);
    f=good; w32(f.bytes+SECTIONS+36,0x20000020); reject_unwind(&f,"unwind-section",1,0);
    /* Function ending in zero-fill is not file-backed, even if virtual RX. */
    f=good; w32(f.bytes+SECTIONS+8,0x400); w32(f.bytes+0xa1c,0x4300); reject_unwind(&f,"unwind-section",1,0);
    /* Raw record ends before the declared slot array; virtual zero-fill is no proof. */
    f=good; w32(f.bytes+SECTIONS+40+8,0x800); w32(f.bytes+0xa08,0x85fc);
    memcpy(f.bytes+0xbfc,(uint8_t[]){1,7,3,0},4); reject_unwind(&f,"offset",1,0);
    /* .pdata itself cannot serve as a partially overlapping unwind record. */
    f=good; w32(f.bytes+0xa08,0x8410); reject_unwind(&f,"version",1,0);
    /* p.permissions is computed using a simulated 16KiB host page, without
     * changing the real host. Metadata R and a separate RW section share it. */
    reset_tracking(); f=good; page_override=16384;
    w32(f.bytes+OPT+32,0x1000); w32(f.bytes+SECTIONS+2*40+12,0x9000);
    pm_pe_image image={0}; char error[192]; resolver_state state={0};
    CHECK(!pm_pe_load_synthetic_unwind_exe(f.bytes,sizeof f.bytes,resolve,&state,1,&image,error,sizeof error));
    CHECK(strstr(error,"unwind-pages") && !map_calls && !state.calls && !live_allocations);
    reset_tracking();
}
static void test_unwind_fixups(void) {
    fixture good=unwind_fixture(),f;
    /* Full/partial DIR64 overlaps with .pdata, .xdata and function/epilog code. */
    const uint32_t targets[]={0x8400,0x8430,0x4008,0x3ff9,0x83f9,0x83fa,0x83fb,0x83fc,0x83fd,0x83fe,0x83ff,0x8429};
    for (unsigned i=0;i<sizeof targets/sizeof *targets;++i) {
        f=good; uint32_t target=targets[i];
        w32(f.bytes+0xe00,target&~0xfffu); w16(f.bytes+0xe08,(uint16_t)(0xa000|(target&0xfff)));
        reject_unwind(&f,target==0x3ff9?"file-backed":"unwind-fixup",0,0);
    }
    f=good; w32(f.bytes+0x610,0x8400); reject_unwind(&f,"unwind-fixup",0,0);
    /* First slot is permitted but its ZERO terminal slot touches xdata. It must
     * be refused too; one preceding resolver call is expected, not hidden. */
    f=good; w32(f.bytes+0x610,0x8428); reject_unwind(&f,"unwind-fixup",0,1);
    f=good; w32(f.bytes+0x600,0x8208); w32(f.bytes+0x610,0x8430);
    reject_unwind(&f,"unwind-fixup",0,0);
}
typedef struct { const pm_pe_image *image; int refused_view,refused_unload,untouched; } thread_proof;
static void *wrong_thread(void *opaque) {
    thread_proof *proof=opaque; char error[128]; pm_unwind_image view;
    memset(&view,0xa7,sizeof view); pm_unwind_image before=view;
    proof->refused_view=!pm_pe_unwind_view(proof->image,&view,error,sizeof error);
    proof->untouched=!memcmp(&view,&before,sizeof view);
    proof->refused_unload=!pm_pe_unload((pm_pe_image *)proof->image);
    return NULL;
}
static void test_unwind_lifetime(void) {
    reset_tracking(); fixture f=unwind_fixture(),original=f;
    pm_pe_image image={0}; char error[192]; resolver_state state={0};
    CHECK(pm_pe_load_synthetic_unwind_exe(f.bytes,sizeof f.bytes,resolve,&state,1,&image,error,sizeof error));
    CHECK(image.synthetic_unwind && !image.synthetic_dll && !error[0]);
    CHECK(live_mappings==1 && live_allocations==2 && !wx_requests);
    pm_unwind_image view;
    CHECK(pm_pe_unwind_view(&image,&view,error,sizeof error));
    CHECK(view.address==(uintptr_t)image.mapping && view.size==0x14000 && view.function_count==3);
    CHECK(view.catalog_complete==1 && view.allow_leaf==0 && view.bytes!=(const uint8_t *)image.mapping);
    CHECK(!memcmp(view.bytes+0x4000,(uint8_t *)image.mapping+0x4000,48));
    CHECK(!memcmp(view.bytes+0x8400,(uint8_t *)image.mapping+0x8400,36));
    for (unsigned i=0;i<3;++i) {
        CHECK(view.functions[i].begin_rva==0x4000+16*i && view.functions[i].end_rva==0x4010+16*i);
        CHECK(view.functions[i].unwind_rva==0x8430+16*i);
        CHECK(!memcmp(view.bytes+0x8430+16*i,(uint8_t *)image.mapping+0x8430+16*i,12));
    }
    CHECK(view.bytes[0xc000]==0 && view.bytes[0x8300]==0); /* unprojected regions */
    CHECK(u64((uint8_t *)image.mapping+0x8300)==(uintptr_t)&fixture_target_never_called);
    CHECK(!memcmp(&f,&original,sizeof f));
    f.bytes[0xa00]=0xff; CHECK(view.functions[0].begin_rva==0x4000);
    pm_pe_image copy=image;
    memset(&view,0xa7,sizeof view); pm_unwind_image sentinel=view;
    CHECK(!pm_pe_unwind_view(&copy,&view,error,sizeof error) && !memcmp(&view,&sentinel,sizeof view));
    CHECK(!pm_pe_unload(&copy));
    uint32_t entry=image.entrypoint_rva; image.entrypoint_rva++;
    CHECK(!pm_pe_unwind_view(&image,&view,error,sizeof error)); image.entrypoint_rva=entry;
    thread_proof proof={.image=&image}; pthread_t thread;
    CHECK(!pthread_create(&thread,NULL,wrong_thread,&proof)); CHECK(!pthread_join(thread,NULL));
    CHECK(proof.refused_view && proof.refused_unload && proof.untouched);
    fail_unmapping=1; CHECK(!pm_pe_unload(&image));
    CHECK(image.synthetic_unwind && live_allocations==2 && live_mappings==1);
    CHECK(pm_pe_unwind_view(&image,&view,error,sizeof error));
    fail_unmapping=0; CHECK(pm_pe_unload(&image));
    CHECK(!image.mapping && !image.synthetic_unwind && !live_allocations && !live_mappings);
    memset(&view,0xa7,sizeof view); sentinel=view;
    CHECK(!pm_pe_unwind_view(&image,&view,error,sizeof error) && !memcmp(&view,&sentinel,sizeof view));
    CHECK(!pm_pe_unwind_view(NULL,&view,error,sizeof error));
}
static int mutate_code_resolver(void *context,const char *dll,const char *name,uint16_t ordinal,int by_ordinal,uintptr_t *address) {
    int ok=resolve(context,dll,name,ordinal,by_ordinal,address);
    ((uint8_t *)last_mapping)[0x4000]^=1; /* controlled hostile callback double */
    return ok;
}
static void test_unwind_cleanup(void) {
    fixture f=unwind_fixture(); pm_pe_image image={0}; char error[192]; resolver_state state;
    for (unsigned at=1;at<=3;++at) {
        reset_tracking(); state=(resolver_state){0}; fail_allocation_at=at;
        CHECK(!pm_pe_load_synthetic_unwind_exe(f.bytes,sizeof f.bytes,resolve,&state,1,&image,error,sizeof error));
        CHECK(strstr(error,"allocation-failed") && !live_allocations && !map_calls && !state.calls);
    }
    reset_tracking(); state=(resolver_state){0}; fail_mapping=1;
    CHECK(!pm_pe_load_synthetic_unwind_exe(f.bytes,sizeof f.bytes,resolve,&state,1,&image,error,sizeof error));
    CHECK(!live_allocations && !image.mapping && !state.calls);
    reset_tracking(); state=(resolver_state){.reject_at=1};
    CHECK(!pm_pe_load_synthetic_unwind_exe(f.bytes,sizeof f.bytes,resolve,&state,1,&image,error,sizeof error));
    CHECK(!live_allocations && !live_mappings && strstr(error,"unresolved-import"));
    reset_tracking(); state=(resolver_state){0};
    CHECK(!pm_pe_load_synthetic_unwind_exe(f.bytes,sizeof f.bytes,mutate_code_resolver,&state,1,&image,error,sizeof error));
    CHECK(strstr(error,"snapshot-mismatch") && !live_allocations && !live_mappings);
    reset_tracking(); state=(resolver_state){0}; fail_protection_at=1; fail_unmapping=1;
    CHECK(!pm_pe_load_synthetic_unwind_exe(f.bytes,sizeof f.bytes,resolve,&state,1,&image,error,sizeof error));
    CHECK(strstr(error,"cleanup-failed") && image.mapping && !image.synthetic_unwind && !live_allocations);
    pm_unwind_image view;
    CHECK(!pm_pe_unwind_view(&image,&view,error,sizeof error));
    fail_unmapping=0; CHECK(pm_pe_unload(&image)); reset_tracking();
}
int main(void) {
    test_unwind_refusals(); test_unwind_fixups(); test_unwind_lifetime(); test_unwind_cleanup();
    CHECK(!live_allocations && !live_mappings && !wx_requests);
    printf("PASS: %u embedded unwind loader checks; no PE executed; liveMappings=0; liveAllocations=0\n",checks);
    return 0;
}
