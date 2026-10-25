#include "x64_unwind.h"

#include <stdio.h>
#include <string.h>

/* Primary Microsoft sources, consulted 2026-10-25:
 * https://learn.microsoft.com/en-us/cpp/build/exception-handling-x64
 * https://learn.microsoft.com/en-us/cpp/build/prolog-and-epilog
 * Scope and explicit host attestations are documented in x64_unwind.h. */

typedef struct unwind_op {
    uint64_t amount;
    uint8_t code_offset, reg;
    int push;
} unwind_op;

typedef struct unwind_record {
    uint8_t prolog;
    size_t count;
    unwind_op ops[PM_UNWIND_MAX_SLOTS];
} unwind_record;

static int fail(char *error,size_t cap,const char *message) {
    if (error && cap) snprintf(error,cap,"%s",message);
    return 0;
}
static uint16_t read16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | (uint16_t)p[1]<<8);
}
static uint32_t read32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}
static uint64_t read64(const uint8_t *p) {
    return (uint64_t)read32(p) | (uint64_t)read32(p+4)<<32;
}
static int nonvolatile(unsigned reg) {
    return reg==3 || reg==5 || reg==6 || reg==7 || (reg>=12 && reg<=15);
}
static const uint8_t *span(const pm_unwind_image *image,uint32_t rva,size_t bytes) {
    return rva<=image->size && bytes<=image->size-rva ? image->bytes+rva : NULL;
}

static int parse_record(const pm_unwind_image *image,const pm_runtime_function *function,
    unwind_record *record,char *error,size_t cap) {
    const uint8_t *p=span(image,function->unwind_rva,4);
    if (!p || !function->unwind_rva || function->unwind_rva%4)
        return fail(error,cap,"invalid-unwind-rva");
    if ((p[0]&7)!=1) return fail(error,cap,"unsupported-unwind-version");
    if (p[0]>>3) return fail(error,cap,"unsupported-unwind-flags-or-chain");
    if (p[3]) return fail(error,cap,"unsupported-frame-register");
    unsigned slots=p[2];
    if (slots>PM_UNWIND_MAX_SLOTS || p[1]>function->end_rva-function->begin_rva)
        return fail(error,cap,"invalid-unwind-count-or-prolog");
    if (!span(image,function->unwind_rva,4+2*((slots+1)&~1u)))
        return fail(error,cap,"truncated-unwind-slots");
    memset(record,0,sizeof *record);
    record->prolog=p[1];
    unsigned last=(unsigned)record->prolog+1;
    uint64_t total=0;
    int seen_push=0;
    for (unsigned slot=0;slot<slots;) {
        const uint8_t *code=p+4+2*slot;
        unsigned opcode=code[1]&15, info=code[1]>>4;
        if (!code[0] || code[0]>record->prolog || code[0]>=last)
            return fail(error,cap,"invalid-unwind-code-offset");
        last=code[0];
        unwind_op op={0}; op.code_offset=code[0];
        unsigned consumed=1;
        if (opcode==0) {
            if (!nonvolatile(info)) return fail(error,cap,"unsupported-push-register");
            op.push=1; op.reg=(uint8_t)info; op.amount=8;
        } else if (opcode==2) {
            op.amount=info*8+8;
        } else if (opcode==1) {
            if (info>1) return fail(error,cap,"invalid-alloc-large-opinfo");
            consumed=info==0?2:3;
            if (slot+consumed>slots) return fail(error,cap,"truncated-alloc-large");
            op.amount=info==0?(uint64_t)read16(code+2)*8:read32(code+2);
            if (!op.amount || op.amount%8) return fail(error,cap,"invalid-alloc-large-size");
            if ((info==0 && op.amount<136) || (info==1 && op.amount<524288))
                return fail(error,cap,"nonminimal-alloc-large-encoding");
        } else return fail(error,cap,"unsupported-unwind-opcode");
        if (!op.push && seen_push) return fail(error,cap,"invalid-push-order");
        if (op.push) seen_push=1;
        if (op.amount>PM_UNWIND_MAX_STACK-total)
            return fail(error,cap,"unwind-stack-budget-exceeded");
        total+=op.amount;
        record->ops[record->count++]=op;
        slot+=consumed; /* Operand slots are never interpreted as instructions. */
    }
    return 1;
}

static int stack_advance(const pm_unwind_stack *stack,pm_x64_context *ctx,uint64_t count) {
    uint64_t rsp=ctx->gpr[4];
    if (rsp<stack->address || rsp-stack->address>stack->size ||
        count>stack->size-(rsp-stack->address)) return 0;
    ctx->gpr[4]+=count;
    return 1;
}
static int stack_pop(const pm_unwind_stack *stack,pm_x64_context *ctx,uint64_t *value) {
    uint64_t rsp=ctx->gpr[4];
    if (!stack_advance(stack,ctx,8)) return 0;
    *value=read64(stack->bytes+(size_t)(rsp-stack->address));
    return 1;
}
static int apply(const unwind_op *op,const pm_unwind_stack *stack,
    pm_x64_context *ctx,pm_unwind_result *result) {
    if (op->push) {
        if (!stack_pop(stack,ctx,&ctx->gpr[op->reg])) return 0;
        result->restored_nonvolatile_mask|=UINT32_C(1)<<op->reg;
        ++result->stack_words_read;
    } else if (!stack_advance(stack,ctx,op->amount)) return 0;
    ++result->operations_applied;
    return 1;
}

/* 1=recognized exact epilog suffix, 0=not an epilog candidate, -1=plausible but
 * unsupported or malformed. No caller-supplied BODY override exists. */
static int epilog(const pm_unwind_image *image,const pm_runtime_function *function,
    uint32_t pc,const unwind_record *record,unwind_op *ops,size_t *count) {
    const uint8_t *code=image->bytes+pc;
    size_t available=function->end_rva-pc;
    uint8_t first=code[0];
    int candidate=(first>=0x58 && first<=0x5f) || first==0xc3 || first==0xc2 ||
        first==0xca || first==0xcb || first==0xe9 || first==0xeb;
    if (first==0xff) candidate=available==1 || ((code[1]>>3)&7)==4 || ((code[1]>>3)&7)==5;
    /* Any legacy prefix at a possible tail is conservatively unsupported. */
    if (first==0x66 || first==0x67 || first==0xf0 || first==0xf2 || first==0xf3 ||
        first==0x2e || first==0x36 || first==0x3e || first==0x26 || first==0x64 || first==0x65)
        return -1;
    if (first>=0x40 && first<=0x4f) {
        if (available<2) return -1;
        uint8_t next=code[1];
        if ((next>=0x40 && next<=0x4f) || next==0x66 || next==0x67 ||
            next==0xf0 || next==0xf2 || next==0xf3 || next==0x2e || next==0x36 ||
            next==0x3e || next==0x26 || next==0x64 || next==0x65) return -1;
        if ((next>=0x58 && next<=0x5f) || next==0xc3 || next==0xc2 || next==0xca || next==0xcb || next==0xe9 || next==0xeb)
            candidate=1;
        if (next==0xff && (available<3 || ((code[2]>>3)&7)==4 || ((code[2]>>3)&7)==5)) candidate=1;
        if (next==0x81 || next==0x83) {
            if (available<3) return -1;
            if ((code[2]&7)==4) candidate=1;
        }
        if (next==0x8d || next==0x8b) {
            if (available<3) return -1;
            if (((code[2]>>3)&7)==4) return -1;
        }
        if (next==0x89) {
            if (available<3) return -1;
            if ((code[2]&0xc7)==0xc4) return -1;
        }
    }
    if (!candidate) return 0;
    size_t at=0,n=0;
    if (available>=3 && code[0]==0x48 && (code[1]==0x83 || code[1]==0x81) && code[2]==0xc4) {
        size_t instruction=code[1]==0x83?4:7;
        if (available<instruction) return -1;
        uint64_t amount=instruction==4?code[3]:read32(code+3);
        uint64_t signed_limit=instruction==4?INT8_MAX:INT32_MAX;
        if (!amount || amount>signed_limit || amount%8 || amount>PM_UNWIND_MAX_STACK) return -1;
        ops[n++]=(unwind_op){.amount=amount}; at=instruction;
    }
    for (;;) {
        if (at>=available || at>=PM_UNWIND_MAX_EPILOG_BYTES) return -1;
        if (code[at]==0xc3) { ++at; break; }
        unsigned reg;
        if (code[at]>=0x58 && code[at]<=0x5f) reg=code[at++]-0x58;
        else if (code[at]==0x41 && at+1<available && code[at+1]>=0x58 && code[at+1]<=0x5f) {
            reg=8+code[at+1]-0x58; at+=2;
        } else return -1;
        if (!nonvolatile(reg) || n==PM_UNWIND_MAX_SLOTS) return -1;
        ops[n++]=(unwind_op){.amount=8,.reg=(uint8_t)reg,.push=1};
    }
    if (at>PM_UNWIND_MAX_EPILOG_BYTES || n>record->count) return -1;
    /* Validate the remainder rather than replaying the complete prolog. */
    size_t start=record->count-n;
    for (size_t i=0;i<n;++i) {
        const unwind_op *expected=&record->ops[start+i];
        if (ops[i].push!=expected->push || ops[i].amount!=expected->amount ||
            (ops[i].push && ops[i].reg!=expected->reg)) return -1;
    }
    *count=n;
    return 1;
}

int pm_x64_unwind_one(const pm_unwind_image *image,const pm_unwind_stack *stack,
    const pm_x64_context *input,pm_x64_context *output,pm_unwind_result *result,
    char *error,size_t error_capacity) {
    if (error && error_capacity) error[0]=0;
    if (!image || !stack || !input || !output || !result || !image->bytes || !stack->bytes ||
        !image->size || image->size>PM_UNWIND_MAX_IMAGE || !stack->size || stack->size>PM_UNWIND_MAX_STACK ||
        image->address>UINT64_MAX-image->size || stack->address>UINT64_MAX-stack->size ||
        image->function_count>PM_UNWIND_MAX_FUNCTIONS || (image->function_count && !image->functions))
        return fail(error,error_capacity,"invalid-view-or-argument");
    if (image->catalog_complete!=1 || (image->allow_leaf!=0 && image->allow_leaf!=1))
        return fail(error,error_capacity,"incomplete-or-invalid-catalogue");
    if (input->rip<image->address || input->rip-image->address>=image->size)
        return fail(error,error_capacity,"control-pc-outside-image");
    if (input->gpr[4]%8 || input->gpr[4]<stack->address || input->gpr[4]-stack->address>stack->size)
        return fail(error,error_capacity,"invalid-stack-pointer");
    uint32_t pc=(uint32_t)(input->rip-image->address);
    const pm_runtime_function *selected=NULL;
    unwind_record selected_record={0};
    uint32_t previous_end=0;
    for (size_t i=0;i<image->function_count;++i) {
        const pm_runtime_function *function=&image->functions[i];
        if (function->begin_rva>=function->end_rva || function->end_rva>image->size ||
            (i && function->begin_rva<previous_end))
            return fail(error,error_capacity,"invalid-or-overlapping-function-table");
        previous_end=function->end_rva;
        unwind_record record;
        if (!parse_record(image,function,&record,error,error_capacity)) return 0;
        if (pc>=function->begin_rva && pc<function->end_rva) { selected=function; selected_record=record; }
    }
    pm_x64_context next=*input;
    pm_unwind_result proof={0};
    if (!selected) {
        if (!image->allow_leaf) return fail(error,error_capacity,"leaf-without-entry-not-authorized");
        proof.phase=PM_UNWIND_LEAF;
    } else {
        uint32_t offset=pc-selected->begin_rva;
        if (offset<selected_record.prolog) {
            proof.phase=PM_UNWIND_PROLOG;
            for (size_t i=0;i<selected_record.count;++i) {
                const unwind_op *op=&selected_record.ops[i];
                if (op->code_offset<=offset && !apply(op,stack,&next,&proof))
                    return fail(error,error_capacity,"stack-truncated-during-prolog");
            }
        } else {
            unwind_op remainder[PM_UNWIND_MAX_SLOTS]; size_t count=0;
            int found=epilog(image,selected,pc,&selected_record,remainder,&count);
            if (found<0) return fail(error,error_capacity,"unsupported-or-invalid-epilog");
            proof.phase=found?PM_UNWIND_EPILOG:
                offset==selected_record.prolog?PM_UNWIND_PROLOG:PM_UNWIND_BODY;
            const unwind_op *ops=found?remainder:selected_record.ops;
            if (!found) count=selected_record.count;
            for (size_t i=0;i<count;++i) {
                if (!apply(&ops[i],stack,&next,&proof))
                    return fail(error,error_capacity,"stack-truncated-during-unwind");
            }
        }
    }
    if (!stack_pop(stack,&next,&next.rip)) return fail(error,error_capacity,"stack-truncated-at-return");
    ++proof.stack_words_read;
    proof.stack_advance=next.gpr[4]-input->gpr[4];
    *output=next;
    *result=proof;
    return 1;
}
