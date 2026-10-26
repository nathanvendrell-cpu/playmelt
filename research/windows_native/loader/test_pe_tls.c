/* Inert CPU fixtures and exact existing loader fault doubles; no guest call. */
#define main pm_tls_existing_loader_main
#include "test_pe_loader.c"
#undef main

static fixture tls_fixture(void) {
    fixture f=make_fixture(); directory(&f,9,0x8400,40);
    w64(f.bytes+0xa00,IMAGE_BASE+0x8440); w64(f.bytes+0xa08,IMAGE_BASE+0x8450);
    w64(f.bytes+0xa10,IMAGE_BASE+0xc040); w64(f.bytes+0xa18,IMAGE_BASE+0x8480);
    w32(f.bytes+0xa20,16); w32(f.bytes+0xa24,0x00500000);
    for (unsigned i=0;i<16;++i) f.bytes[0xa40+i]=(uint8_t)(0x11+i);
    w32(f.bytes+0xc40,UINT32_MAX);
    directory(&f,5,0x10000,28); w32(f.bytes+0xe0c,0x8000); w32(f.bytes+0xe10,16);
    for (unsigned i=0;i<4;++i) w16(f.bytes+0xe14+2*i,(uint16_t)(0xa400+8*i));
    return f;
}
static void reject_tls(fixture *f,const char *expected,int premap,unsigned calls) {
    reset_tracking(); fixture original=*f; pm_pe_image image={0}; resolver_state state={0}; char error[192];
    CHECK(!pm_pe_load_synthetic_tls_exe(f->bytes,sizeof f->bytes,resolve,&state,&image,error,sizeof error));
    CHECK(strstr(error,expected)); CHECK(!image.mapping && !image.synthetic_tls && !image.lifetime);
    CHECK(!live_mappings && !live_allocations && !wx_requests && state.calls==calls);
    CHECK(premap?map_calls==0:map_calls==1); CHECK(!memcmp(&original,f,sizeof original));
}
static void tls_refusals(void) {
    fixture good=tls_fixture(),f=good; reject_fixture(&f,"TLS");
    w16(f.bytes+0x96,0x2022); reject_synthetic(&f,"TLS");
    reset_tracking(); pm_pe_image image={0}; resolver_state state={0}; char error[192];
    CHECK(!pm_pe_load_synthetic_unwind_exe(good.bytes,sizeof good.bytes,resolve,&state,1,&image,error,sizeof error));
    CHECK(strstr(error,"TLS") && !map_calls && !state.calls && !live_allocations);
    reject_tls(&f,"EXE",1,0);
    f=good; directory(&f,9,0,0); reject_tls(&f,"directory 9",1,0);
    f=good; directory(&f,9,0x8400,39); reject_tls(&f,"40-byte",1,0);
    f=good; directory(&f,9,0x8401,40); reject_tls(&f,"40-byte",1,0);
    f=good; w32(f.bytes+OPT+56,0x104000); reject_tls(&f,"1 MiB",1,0);
    for (unsigned field=0;field<4;++field) {
        f=good; w64(f.bytes+0xa00+8*field,IMAGE_BASE-1); reject_tls(&f,"tls-va",1,0);
        f=good; w64(f.bytes+0xa00+8*field,UINT64_MAX); reject_tls(&f,"tls-va",1,0);
    }
    f=good; w64(f.bytes+0xa08,IMAGE_BASE+0x8440); reject_tls(&f,"empty/reversed",1,0);
    f=good; w64(f.bytes+0xa08,IMAGE_BASE+0x843f); reject_tls(&f,"empty/reversed",1,0);
    f=good; w32(f.bytes+0xa20,UINT32_MAX); reject_tls(&f,"4096",1,0);
    f=good; w32(f.bytes+0xa20,4081); reject_tls(&f,"4096",1,0);
    f=good; w64(f.bytes+0xa08,IMAGE_BASE+0x9441); reject_tls(&f,"4096",1,0);
    for (unsigned bit=0;bit<32;++bit) if (bit<20 || bit>23) {
        f=good; w32(f.bytes+0xa24,1u<<bit); reject_tls(&f,"characteristics",1,0);
    }
    for (unsigned align=8;align<16;++align) {
        f=good; w32(f.bytes+0xa24,align<<20); reject_tls(&f,"characteristics",1,0);
    }
    f=good; w64(f.bytes+0xa10,IMAGE_BASE+0xc041); reject_tls(&f,"aligned DWORD",1,0);
    f=good; w64(f.bytes+0xa10,IMAGE_BASE+0xc200); reject_tls(&f,"tls-section",1,0);
    f=good; w64(f.bytes+0xa18,IMAGE_BASE+0x8481); reject_tls(&f,"callbacks",1,0);
    f=good; w64(f.bytes+0xa80,IMAGE_BASE+0x4000); reject_tls(&f,"nonempty callback",1,0);
    f=good; w32(f.bytes+SECTIONS+40+36,0xc0000040); reject_tls(&f,"tls-section",1,0);
    f=good; w32(f.bytes+SECTIONS+2*40+36,0x40000040); reject_tls(&f,"tls-section",1,0);
    f=good; w64(f.bytes+0xa00,IMAGE_BASE+0x8410); w64(f.bytes+0xa08,IMAGE_BASE+0x8420); reject_tls(&f,"tls-overlap",1,0);
    f=good; w64(f.bytes+0xa18,IMAGE_BASE+0x8440); memset(f.bytes+0xa40,0,8); reject_tls(&f,"tls-overlap",1,0);
    /* R metadata sharing a simulated16KiB page with RW data is not immutable. */
    reset_tracking(); f=good; page_override=16384; state=(resolver_state){0};
    w32(f.bytes+OPT+32,0x1000); w32(f.bytes+SECTIONS+2*40+12,0x9000); w64(f.bytes+0xa10,IMAGE_BASE+0x9040);
    CHECK(!pm_pe_load_synthetic_tls_exe(f.bytes,sizeof f.bytes,resolve,&state,&image,error,sizeof error));
    CHECK(strstr(error,"tls-pages") && !map_calls && !state.calls && !live_allocations);
    reset_tracking();
}
static void tls_fixups(void) {
    fixture good=tls_fixture(),f;
    for (unsigned missing=0;missing<4;++missing) {
        f=good; w16(f.bytes+0xe14+2*missing,0); reject_tls(&f,"missing-tls-relocations",0,1);
    }
    f=good; w16(f.bytes+0xe1a,0xa400); reject_tls(&f,"tls-fixup",0,0);
    const uint32_t targets[]={0x83f9,0x83fa,0x83fb,0x83fc,0x83fd,0x83fe,0x83ff,
        0x8401,0x8420,0x8439,0x843f,0x8440,0x844f,0x8479,0x847f,0x8480,0xc039,0xc03f,0xc040,0xc043};
    for (unsigned i=0;i<sizeof targets/sizeof *targets;++i) {
        f=good; w32(f.bytes+0xe00,targets[i]&~0xfffu); w16(f.bytes+0xe08,(uint16_t)(0xa000|(targets[i]&0xfff)));
        reject_tls(&f,"tls-fixup",0,0);
    }
    const uint32_t iats[]={0x8400,0x8440,0x8480,0xc040,0xc038};
    for (unsigned i=0;i<sizeof iats/sizeof *iats;++i) {
        f=good; w32(f.bytes+0x610,iats[i]); reject_tls(&f,"tls-fixup",0,i==4?1:0);
    }
    /* Zero terminator only overlaps template; preceding resolver call occurred. */
    f=good; w32(f.bytes+0x610,0x8438); reject_tls(&f,"tls-fixup",0,1);
    /* Even a zero relocation delta must not excuse absent mandatory entries. */
    uint8_t bytes[64]={0}; struct pm_pe_tls_control c={.required_fixups=15};
    pm_loader p={0}; char error[128]; p.mapping=bytes; p.image_base=(uintptr_t)bytes;
    p.tls=&c; p.error=error; p.error_cap=sizeof error;
    CHECK(relocate(&p)); CHECK(!finalize_tls(&p)); CHECK(strstr(error,"missing-tls-relocations"));
}
typedef struct { pm_pe_image *image; int refused_view,untouched,refused_unload; } tls_thread_check;
static void *tls_wrong_thread(void *opaque) {
    tls_thread_check *s=opaque; pm_pe_tls_state view; memset(&view,0xa7,sizeof view); pm_pe_tls_state old=view; char error[128];
    s->refused_view=!pm_pe_tls_view(s->image,&view,error,sizeof error);
    s->untouched=!memcmp(&view,&old,sizeof view); s->refused_unload=!pm_pe_unload(s->image); return NULL;
}
static void tls_success(void) {
    for (unsigned alignment=0;alignment<=7;++alignment) {
        reset_tracking(); fixture f=tls_fixture(),original; w32(f.bytes+0xa24,alignment<<20); original=f;
        pm_pe_image image={0}; resolver_state state={0}; char error[192]; pm_pe_tls_state view;
        CHECK(pm_pe_load_synthetic_tls_exe(f.bytes,sizeof f.bytes,resolve,&state,&image,error,sizeof error));
        CHECK(pm_pe_tls_view(&image,&view,error,sizeof error));
        CHECK(view.index==1 && view.index_rva==0xc040 && u32((uint8_t *)image.mapping+view.index_rva)==1);
        CHECK(view.block_size==32 && view.template_size==16 && view.zero_fill==16 && view.vector[0]==0 && view.vector[1]==(uintptr_t)view.block);
        CHECK(view.alignment==(alignment?1u<<(alignment-1):16u) && (uintptr_t)view.block%view.alignment==0);
        CHECK(!memcmp(view.block,f.bytes+0xa40,16));
        for (unsigned i=16;i<32;++i) CHECK(((uint8_t *)view.block)[i]==0);
        ((uint8_t *)view.block)[0]=0x77; CHECK(((uint8_t *)image.mapping)[0x8440]==0x11);
        CHECK(!memcmp(&f,&original,sizeof f)); CHECK(live_allocations==2 && live_mappings==1 && !wx_requests);
        CHECK(actual_permissions((uint8_t *)image.mapping+0x8400)==PROT_READ);
        CHECK(actual_permissions((uint8_t *)image.mapping+0xc040)==(PROT_READ|PROT_WRITE));
        if (alignment==0) {
            pm_pe_tls_state sentinel; memset(&sentinel,0xa7,sizeof sentinel); view=sentinel; pm_pe_image copy=image;
            CHECK(!pm_pe_tls_view(&copy,&view,error,sizeof error) && !memcmp(&view,&sentinel,sizeof view)); CHECK(!pm_pe_unload(&copy));
            struct pm_pe_tls_control *saved=image.synthetic_tls; image.synthetic_tls=NULL;
            CHECK(!pm_pe_tls_view(&image,&view,error,sizeof error)); image.synthetic_tls=saved;
            w32((uint8_t *)image.mapping+0xc040,2); CHECK(!pm_pe_tls_view(&image,&view,error,sizeof error)); w32((uint8_t *)image.mapping+0xc040,1);
            tls_thread_check s={.image=&image}; pthread_t t;
            CHECK(!pthread_create(&t,NULL,tls_wrong_thread,&s)); CHECK(!pthread_join(t,NULL)); CHECK(s.refused_view && s.untouched && s.refused_unload);
            fail_unmapping=1; CHECK(!pm_pe_unload(&image)); CHECK(live_allocations==2 && live_mappings==1 && image.synthetic_tls);
            CHECK(!pm_pe_tls_view(&image,&view,error,sizeof error) && !memcmp(&view,&sentinel,sizeof view)); fail_unmapping=0;
        }
        CHECK(pm_pe_unload(&image)); CHECK(!image.mapping && !image.lifetime && !image.synthetic_tls && !live_allocations && !live_mappings);
    }
    /* Explicitly absent callback array; maximum block with actual zero-fill. */
    reset_tracking(); fixture f=tls_fixture(); w64(f.bytes+0xa18,0); w16(f.bytes+0xe1a,0); w32(f.bytes+0xa20,4080);
    pm_pe_image image={0}; resolver_state state={0}; char error[128]; pm_pe_tls_state view;
    CHECK(pm_pe_load_synthetic_tls_exe(f.bytes,sizeof f.bytes,resolve,&state,&image,error,sizeof error));
    CHECK(pm_pe_tls_view(&image,&view,error,sizeof error) && view.block_size==4096);
    uint8_t zero[4080]={0}; CHECK(!memcmp((uint8_t *)view.block+16,zero,sizeof zero)); CHECK(pm_pe_unload(&image));
    reset_tracking(); f=tls_fixture(); w32(f.bytes+0xa20,0); state=(resolver_state){0};
    CHECK(pm_pe_load_synthetic_tls_exe(f.bytes,sizeof f.bytes,resolve,&state,&image,error,sizeof error));
    CHECK(pm_pe_tls_view(&image,&view,error,sizeof error) && view.block_size==16 && view.zero_fill==0); CHECK(pm_pe_unload(&image));
}
static unsigned mutation_offset;
static int mutate_tls(void *ctx,const char *dll,const char *name,uint16_t ordinal,int by_ordinal,uintptr_t *address) {
    int ok=resolve(ctx,dll,name,ordinal,by_ordinal,address); ((uint8_t *)last_mapping)[mutation_offset]^=1; return ok;
}
static void tls_cleanup(void) {
    fixture f=tls_fixture(); pm_pe_image image={0}; resolver_state state; char error[192];
    for (unsigned at=1;at<=3;++at) {
        reset_tracking(); state=(resolver_state){0}; fail_allocation_at=at;
        CHECK(!pm_pe_load_synthetic_tls_exe(f.bytes,sizeof f.bytes,resolve,&state,&image,error,sizeof error));
        CHECK(strstr(error,"allocation-failed") && !map_calls && !state.calls && !live_allocations);
    }
    reset_tracking(); state=(resolver_state){0}; fail_mapping=1;
    CHECK(!pm_pe_load_synthetic_tls_exe(f.bytes,sizeof f.bytes,resolve,&state,&image,error,sizeof error)); CHECK(!live_allocations && !live_mappings);
    for (unsigned at=1;at<=4;++at) {
        reset_tracking(); state=(resolver_state){0}; fail_protection_at=(int)at;
        CHECK(!pm_pe_load_synthetic_tls_exe(f.bytes,sizeof f.bytes,resolve,&state,&image,error,sizeof error));
        CHECK(strstr(error,"protection-failed") && !live_allocations && !live_mappings && !image.mapping);
    }
    const unsigned offsets[]={0x8400,0x8420,0x8440,0x8480,0xc040};
    for (unsigned i=0;i<sizeof offsets/sizeof *offsets;++i) {
        reset_tracking(); state=(resolver_state){0}; mutation_offset=offsets[i];
        CHECK(!pm_pe_load_synthetic_tls_exe(f.bytes,sizeof f.bytes,mutate_tls,&state,&image,error,sizeof error));
        CHECK(strstr(error,"tls-snapshot-mismatch") && !live_allocations && !live_mappings);
    }
    reset_tracking(); state=(resolver_state){.reject_at=1}; fail_unmapping=1;
    CHECK(!pm_pe_load_synthetic_tls_exe(f.bytes,sizeof f.bytes,resolve,&state,&image,error,sizeof error));
    CHECK(strstr(error,"cleanup-failed") && image.mapping && image.lifetime && image.synthetic_tls && live_allocations==2);
    pm_pe_tls_state view; memset(&view,0xa7,sizeof view); pm_pe_tls_state original=view;
    CHECK(!pm_pe_tls_view(&image,&view,error,sizeof error) && !memcmp(&view,&original,sizeof view));
    fail_unmapping=0; CHECK(pm_pe_unload(&image)); CHECK(!live_allocations && !live_mappings);
    reset_tracking(); state=(resolver_state){0}; fail_protection_at=2; fail_unmapping=1;
    CHECK(!pm_pe_load_synthetic_tls_exe(f.bytes,sizeof f.bytes,resolve,&state,&image,error,sizeof error));
    CHECK(strstr(error,"cleanup-failed") && image.mapping && image.synthetic_tls && live_allocations==2 && live_mappings==1);
    CHECK(!pm_pe_tls_view(&image,&view,error,sizeof error));
    fail_unmapping=0; CHECK(pm_pe_unload(&image)); CHECK(!live_allocations && !live_mappings && !image.synthetic_tls);
}
int main(void) {
    tls_refusals(); tls_fixups(); tls_success(); tls_cleanup();
    CHECK(!live_allocations && !live_mappings && !wx_requests);
    printf("PASS: %u TLS loader checks; no guest execution; allocations=0 mappings=0\n",checks); return 0;
}
