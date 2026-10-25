#include "x64_unwind.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"FAIL %s:%d %s\n",__FILE__,__LINE__,#x); abort(); } } while (0)
static const uint64_t old_rbx=UINT64_C(0x1122334455667788), old_r12=UINT64_C(0x8877665544332211);
static const uint64_t return_pc=UINT64_C(0x140003000);
typedef struct fixture {
    uint8_t code[1024], stack_bytes[512];
    pm_runtime_function functions[2];
    pm_unwind_image image;
    pm_unwind_stack stack;
    pm_x64_context input;
} fixture;
static void w16(void *p,uint16_t n) { uint8_t *b=p; b[0]=(uint8_t)n; b[1]=(uint8_t)(n>>8); }
static void w32(void *p,uint32_t n) { uint8_t *b=p; for(unsigned i=0;i<4;++i)b[i]=(uint8_t)(n>>(8*i)); }
static void w64(void *p,uint64_t n) { uint8_t *b=p; for(unsigned i=0;i<8;++i)b[i]=(uint8_t)(n>>(8*i)); }
static void init(fixture *f) {
    memset(f,0,sizeof *f); memset(f->code,0x90,sizeof f->code);
    f->functions[0]=(pm_runtime_function){0x100,0x180,0x200};
    f->image=(pm_unwind_image){f->code,sizeof f->code,UINT64_C(0x140000000),f->functions,1,1,0};
    f->stack=(pm_unwind_stack){f->stack_bytes,sizeof f->stack_bytes,UINT64_C(0x70000000)};
    const uint8_t metadata[]={1,7,3,0,7,0x42,3,0xc0,1,0x30,0,0};
    const uint8_t prolog[]={0x53,0x41,0x54,0x48,0x83,0xec,0x28};
    const uint8_t epilog[]={0x48,0x83,0xc4,0x28,0x41,0x5c,0x5b,0xc3};
    memcpy(f->code+0x200,metadata,sizeof metadata);
    memcpy(f->code+0x100,prolog,sizeof prolog);
    memcpy(f->code+0x170,epilog,sizeof epilog);
    for(unsigned i=0;i<16;++i) f->input.gpr[i]=UINT64_C(0xabcdef0000000000)+i;
    f->input.gpr[4]=f->stack.address+32; f->input.rip=f->image.address+0x120;
    w64(f->stack_bytes+72,old_r12); w64(f->stack_bytes+80,old_rbx); w64(f->stack_bytes+88,return_pc);
}
static pm_unwind_result success(fixture *f,pm_unwind_phase phase,uint64_t rsp,
    uint32_t mask,uint32_t operations) {
    pm_x64_context output, before=f->input; pm_unwind_result result;
    char error[128];
    CHECK(pm_x64_unwind_one(&f->image,&f->stack,&f->input,&output,&result,error,sizeof error));
    CHECK(!error[0] && !memcmp(&before,&f->input,sizeof before));
    CHECK(result.phase==phase && result.restored_nonvolatile_mask==mask && result.operations_applied==operations);
    CHECK(output.rip==return_pc && output.gpr[4]==f->stack.address+rsp);
    CHECK(result.stack_advance==output.gpr[4]-before.gpr[4]);
    for(unsigned reg=0;reg<16;++reg) {
        if (reg==4) continue;
        uint64_t expected=(mask&(1u<<reg))?(reg==3?old_rbx:old_r12):before.gpr[reg];
        CHECK(output.gpr[reg]==expected);
    }
    return result;
}
static void rejected(fixture *f,const char *fragment) {
    pm_x64_context before=f->input, output; memset(&output,0xa5,sizeof output);
    pm_x64_context sentinel=output;
    pm_unwind_result result; memset(&result,0x5a,sizeof result); pm_unwind_result proof=result;
    char error[128];
    CHECK(!pm_x64_unwind_one(&f->image,&f->stack,&f->input,&output,&result,error,sizeof error));
    if (!strstr(error,fragment)) fprintf(stderr,"Error '%s' expected '%s'\n",error,fragment);
    CHECK(strstr(error,fragment)!=NULL);
    CHECK(!memcmp(&output,&sentinel,sizeof output) && !memcmp(&result,&proof,sizeof result));
    CHECK(!memcmp(&before,&f->input,sizeof before));
}

static void test_frames(void) {
    fixture f; init(&f); uint32_t both=(1u<<3)|(1u<<12);
    pm_unwind_result p=success(&f,PM_UNWIND_BODY,96,both,3); CHECK(p.stack_words_read==3);
    const unsigned offsets[]={0,1,3,7};
    const unsigned pointers[]={88,80,72,32};
    const uint32_t masks[]={0,1u<<3,(1u<<3)|(1u<<12),(1u<<3)|(1u<<12)};
    for(unsigned i=0;i<4;++i) {
        init(&f); f.input.rip=f.image.address+0x100+offsets[i];
        f.input.gpr[4]=f.stack.address+pointers[i];
        success(&f,PM_UNWIND_PROLOG,96,masks[i],i);
    }
    /* Every instruction boundary in the epilog, including its suffixes. */
    const unsigned pcs[]={0x170,0x174,0x176,0x177};
    const unsigned stack_offsets[]={32,72,80,88};
    const uint32_t epilog_masks[]={both,both,1u<<3,0};
    for(unsigned i=0;i<4;++i) {
        init(&f); f.input.rip=f.image.address+pcs[i]; f.input.gpr[4]=f.stack.address+stack_offsets[i];
        success(&f,PM_UNWIND_EPILOG,96,epilog_masks[i],3-i);
    }
    init(&f); f.input.rip=f.image.address+0x180; f.input.gpr[4]=f.stack.address+88;
    rejected(&f,"leaf-without-entry"); f.image.allow_leaf=1;
    success(&f,PM_UNWIND_LEAF,96,0,0); /* EndAddress is exclusive. */
    f.image.function_count=0;
    success(&f,PM_UNWIND_LEAF,96,0,0);
    f.image.catalog_complete=0; rejected(&f,"incomplete");
    init(&f);
    pm_unwind_result result; char error[128];
    CHECK(pm_x64_unwind_one(&f.image,&f.stack,&f.input,&f.input,&result,error,sizeof error));
    CHECK(f.input.rip==return_pc && f.input.gpr[3]==old_rbx && f.input.gpr[12]==old_r12);
}

static void test_large_and_registers(void) {
    fixture f; init(&f);
    uint8_t large0[]={1,7,4,0,7,1,32,0,3,0xc0,1,0x30};
    memcpy(f.code+0x200,large0,sizeof large0);
    w64(f.stack_bytes+288,old_r12); w64(f.stack_bytes+296,old_rbx); w64(f.stack_bytes+304,return_pc);
    success(&f,PM_UNWIND_BODY,312,(1u<<3)|(1u<<12),3);
    /* ALLOC_LARGE opinfo1 consumes two operand slots, including zero CodeOffsets. */
    init(&f); size_t size=524320;
    uint8_t *large_stack=calloc(1,size); CHECK(large_stack!=NULL);
    f.stack.bytes=large_stack; f.stack.size=size; f.input.gpr[4]=f.stack.address;
    const uint8_t large1[]={1,7,5,0,7,0x11,0,0,8,0,3,0xc0,1,0x30,0,0};
    memcpy(f.code+0x200,large1,sizeof large1);
    w64(large_stack+524288,old_r12); w64(large_stack+524296,old_rbx); w64(large_stack+524304,return_pc);
    success(&f,PM_UNWIND_BODY,524312,(1u<<3)|(1u<<12),3);
    f.stack.size=524304; rejected(&f,"at-return"); free(large_stack);
    /* All legal nonvolatile registers, without pretending to restore volatiles. */
    const unsigned regs[]={3,5,6,7,12,13,14,15};
    for(size_t i=0;i<sizeof regs/sizeof *regs;++i) {
        init(&f); f.code[0x201]=1; f.code[0x202]=1; f.code[0x204]=1;
        f.code[0x205]=(uint8_t)(regs[i]<<4); f.code[0x206]=f.code[0x207]=0;
        w64(f.stack_bytes+32,0x123456789); w64(f.stack_bytes+40,return_pc);
        pm_x64_context out; pm_unwind_result proof; char error[128];
        CHECK(pm_x64_unwind_one(&f.image,&f.stack,&f.input,&out,&proof,error,sizeof error));
        CHECK(out.gpr[regs[i]]==0x123456789 && proof.restored_nonvolatile_mask==(1u<<regs[i]));
        CHECK(out.gpr[4]==f.stack.address+48 && out.rip==return_pc);
    }
}

static void test_metadata_rejections(void) {
    fixture f;
    const uint8_t versions[]={0,2,3,4,7};
    for(size_t i=0;i<sizeof versions;++i) { init(&f); f.code[0x200]=versions[i]; rejected(&f,"version"); }
    for(unsigned flags=1;flags<32;++flags) { init(&f); f.code[0x200]=(uint8_t)(1|(flags<<3)); rejected(&f,"flags"); }
    for(unsigned frame=1;frame<256;frame+=17) { init(&f); f.code[0x203]=(uint8_t)frame; rejected(&f,"frame"); }
    const unsigned opcodes[]={3,4,5,6,7,8,9,10,11,12,13,14,15};
    for(size_t i=0;i<sizeof opcodes/sizeof *opcodes;++i) { init(&f); f.code[0x205]=(uint8_t)opcodes[i]; rejected(&f,"opcode"); }
    const unsigned volatile_regs[]={0,1,2,4,8,9,10,11};
    for(size_t i=0;i<sizeof volatile_regs/sizeof *volatile_regs;++i) {
        init(&f); f.code[0x207]=(uint8_t)(volatile_regs[i]<<4); rejected(&f,"register");
    }
    init(&f); f.code[0x204]=0; rejected(&f,"offset");
    init(&f); f.code[0x206]=7; rejected(&f,"offset");
    init(&f); f.code[0x204]=8; rejected(&f,"offset");
    init(&f); f.code[0x202]=65; rejected(&f,"count");
    init(&f); f.code[0x201]=255; rejected(&f,"prolog");
    init(&f); f.functions[0].unwind_rva=0; rejected(&f,"rva");
    init(&f); f.functions[0].unwind_rva=0x201; rejected(&f,"rva");
    init(&f); f.functions[0].unwind_rva=1024; rejected(&f,"rva");
    init(&f); f.image.size=0x20a; rejected(&f,"truncated");
    init(&f); f.code[0x205]=0x21; rejected(&f,"opinfo");
    init(&f); f.code[0x205]=1; f.code[0x202]=1; rejected(&f,"truncated-alloc");
    init(&f); f.code[0x205]=1; f.code[0x206]=f.code[0x207]=0; rejected(&f,"size");
    init(&f); f.code[0x205]=1; w16(f.code+0x206,1); rejected(&f,"nonminimal");
    init(&f); f.code[0x205]=0x11; w32(f.code+0x206,524289); rejected(&f,"size");
    init(&f); f.code[0x205]=0x11; w32(f.code+0x206,PM_UNWIND_MAX_STACK+8); rejected(&f,"budget");
    init(&f); f.code[0x205]=0x30; f.code[0x207]=2; rejected(&f,"push-order");
    init(&f); f.functions[0].end_rva=0x100; rejected(&f,"function-table");
    init(&f); f.functions[0].end_rva=1025; rejected(&f,"function-table");
    init(&f); f.image.function_count=2; f.functions[1]=(pm_runtime_function){0x170,0x190,0x200}; rejected(&f,"overlapping");
    init(&f); f.image.function_count=2; f.functions[1]=(pm_runtime_function){0x180,0x190,0x300};
    f.code[0x300]=2; f.input.rip=f.image.address+0x350; f.image.allow_leaf=1;
    rejected(&f,"version"); /* Bad off-PC metadata cannot open the leaf path. */
}

static void bad_epilog(fixture *f,const uint8_t *code,size_t size) {
    memset(f->code+0x160,0x90,0x20); memcpy(f->code+0x160,code,size);
    f->input.rip=f->image.address+0x160;
    rejected(f,"epilog");
}
static void test_epilog_rejections(void) {
    fixture f;
    static const uint8_t cases[][10]={
        {0x48,0x83,0xc4,0xf8,0xc3}, {0x48,0x81,0xc4,0xf8,0xff,0xff,0xff,0xc3},
        {0x48,0x83,0xc4,0,0xc3}, {0x48,0x83,0xc4,7,0xc3},
        {0x48,0x83,0xc4,0x20,0x41,0x5c,0x5b,0xc3},
        {0x48,0x83,0xc4,0x28,0x5b,0x41,0x5c,0xc3},
        {0x48,0x8d,0x65,0x20,0xc3}, {0x48,0x8b,0xe5,0x5d,0xc3},
        {0xe9,0,0,0,0}, {0xeb,0}, {0xff,0x25,0,0,0,0}, {0xc2,0x20,0},
        {0xf3,0xc3}, {0x48,0xf3,0xc3}, {0x48,0x41,0x5c,0xc3},
        {0x58,0xc3}, {0x5c,0xc3}, {0x41,0x5b,0xc3}, {0x5d,0xc3}
    };
    for(size_t i=0;i<sizeof cases/sizeof *cases;++i) { init(&f); bad_epilog(&f,cases[i],sizeof cases[i]); }
    init(&f); f.code[0x17f]=0x48; f.input.rip=f.image.address+0x17f; rejected(&f,"epilog");
    init(&f); f.code[0x17e]=0x48; f.code[0x17f]=0x83; f.input.rip=f.image.address+0x17e; rejected(&f,"epilog");
    init(&f); f.code[0x17f]=0x5b; f.input.rip=f.image.address+0x17f; rejected(&f,"epilog");
    /* Completed prolog is not an escape hatch around epilog validation. */
    init(&f); f.input.rip=f.image.address+0x107; f.code[0x107]=0xe9; rejected(&f,"epilog");
    const uint8_t unknown[]={0xe9,0xc2,0xf3};
    for(size_t i=0;i<sizeof unknown;++i) {
        init(&f); f.code[0x201]=f.code[0x202]=0;
        f.input.rip=f.image.address+0x100; f.code[0x100]=unknown[i]; rejected(&f,"epilog");
    }
    init(&f); f.code[0x201]=f.code[0x202]=0; f.code[0x100]=0xc3;
    f.input.rip=f.image.address+0x100; f.input.gpr[4]=f.stack.address+88;
    success(&f,PM_UNWIND_EPILOG,96,0,0);
}

static void test_bounds_and_atomic_failure(void) {
    fixture f;
    init(&f); f.stack.size=88; rejected(&f,"at-return");
    init(&f); f.stack.size=80; rejected(&f,"during-unwind");
    init(&f); f.stack.size=71; rejected(&f,"during-unwind");
    init(&f); f.input.gpr[4]++; rejected(&f,"stack-pointer");
    init(&f); f.input.gpr[4]=f.stack.address-8; rejected(&f,"stack-pointer");
    init(&f); f.input.gpr[4]=f.stack.address+f.stack.size+8; rejected(&f,"stack-pointer");
    init(&f); f.stack.address=UINT64_MAX-7; rejected(&f,"invalid-view");
    init(&f); f.image.address=UINT64_MAX-100; rejected(&f,"invalid-view");
    init(&f); f.image.size=PM_UNWIND_MAX_IMAGE+1; rejected(&f,"invalid-view");
    init(&f); f.stack.size=PM_UNWIND_MAX_STACK+1; rejected(&f,"invalid-view");
    init(&f); f.image.function_count=PM_UNWIND_MAX_FUNCTIONS+1; rejected(&f,"invalid-view");
    init(&f); f.image.functions=NULL; rejected(&f,"invalid-view");
    init(&f); f.image.bytes=NULL; rejected(&f,"invalid-view");
    init(&f); f.stack.bytes=NULL; rejected(&f,"invalid-view");
    init(&f); f.image.allow_leaf=2; rejected(&f,"catalogue");
    init(&f); f.input.rip=f.image.address+f.image.size; rejected(&f,"outside-image");
    init(&f); f.input.rip=f.image.address-1; rejected(&f,"outside-image");
    init(&f); f.stack.size=88;
    pm_x64_context before=f.input; pm_unwind_result proof; memset(&proof,0xa5,sizeof proof);
    pm_unwind_result original=proof; char error[2]={'x','y'};
    CHECK(!pm_x64_unwind_one(&f.image,&f.stack,&f.input,&f.input,&proof,error,1));
    CHECK(error[0]==0 && error[1]=='y' && !memcmp(&before,&f.input,sizeof before));
    CHECK(!memcmp(&proof,&original,sizeof proof));
}

int main(void) {
    test_frames(); test_large_and_registers(); test_metadata_rejections();
    test_epilog_rejections(); test_bounds_and_atomic_failure();
    printf("PASS: %u bounded x64 context checks; no code executed/resumed, no SEH\n",checks);
    return 0;
}
