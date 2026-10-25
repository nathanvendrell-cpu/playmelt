#include "x64_unwind_internal.h"

#include <stdio.h>
#include <string.h>

/* Primary Microsoft sources, consulted 2026-10-25:
 * https://learn.microsoft.com/en-us/cpp/build/exception-handling-x64
 * https://learn.microsoft.com/en-us/cpp/build/prolog-and-epilog
 * Scope and explicit host attestations are documented in x64_unwind.h. */

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
    *value=pm_uw_read64(stack->bytes+(size_t)(rsp-stack->address));
    return 1;
}
static int apply(const pm_uw_op *op,const pm_unwind_stack *stack,
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
    uint32_t pc,const pm_uw_record *record,pm_uw_op *ops,size_t *count) {
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
        uint64_t amount=instruction==4?code[3]:pm_uw_read32(code+3);
        uint64_t signed_limit=instruction==4?INT8_MAX:INT32_MAX;
        if (!amount || amount>signed_limit || amount%8 || amount>PM_UNWIND_MAX_STACK) return -1;
        ops[n++]=(pm_uw_op){.amount=amount}; at=instruction;
    }
    for (;;) {
        if (at>=available || at>=PM_UNWIND_MAX_EPILOG_BYTES) return -1;
        if (code[at]==0xc3) { ++at; break; }
        unsigned reg;
        if (code[at]>=0x58 && code[at]<=0x5f) reg=code[at++]-0x58;
        else if (code[at]==0x41 && at+1<available && code[at+1]>=0x58 && code[at+1]<=0x5f) {
            reg=8+code[at+1]-0x58; at+=2;
        } else return -1;
        if (!pm_uw_nonvolatile(reg) || n==PM_UNWIND_MAX_SLOTS) return -1;
        ops[n++]=(pm_uw_op){.amount=8,.reg=(uint8_t)reg,.push=1};
    }
    if (at>PM_UNWIND_MAX_EPILOG_BYTES || n>record->count) return -1;
    /* Validate the remainder rather than replaying the complete prolog. */
    size_t start=record->count-n;
    for (size_t i=0;i<n;++i) {
        const pm_uw_op *expected=&record->ops[start+i];
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
        return pm_uw_fail(error,error_capacity,"invalid-view-or-argument");
    if (image->catalog_complete!=1 || (image->allow_leaf!=0 && image->allow_leaf!=1))
        return pm_uw_fail(error,error_capacity,"incomplete-or-invalid-catalogue");
    if (input->rip<image->address || input->rip-image->address>=image->size)
        return pm_uw_fail(error,error_capacity,"control-pc-outside-image");
    if (input->gpr[4]%8 || input->gpr[4]<stack->address || input->gpr[4]-stack->address>stack->size)
        return pm_uw_fail(error,error_capacity,"invalid-stack-pointer");
    uint32_t pc=(uint32_t)(input->rip-image->address);
    const pm_runtime_function *selected=NULL;
    pm_uw_record selected_record={0};
    if (!pm_uw_validate_catalogue(image,pc,&selected,&selected_record,error,error_capacity)) return 0;
    pm_x64_context next=*input;
    pm_unwind_result proof={0};
    if (!selected) {
        if (!image->allow_leaf) return pm_uw_fail(error,error_capacity,"leaf-without-entry-not-authorized");
        proof.phase=PM_UNWIND_LEAF;
    } else {
        uint32_t offset=pc-selected->begin_rva;
        if (offset<selected_record.prolog) {
            proof.phase=PM_UNWIND_PROLOG;
            for (size_t i=0;i<selected_record.count;++i) {
                const pm_uw_op *op=&selected_record.ops[i];
                if (op->code_offset<=offset && !apply(op,stack,&next,&proof))
                    return pm_uw_fail(error,error_capacity,"stack-truncated-during-prolog");
            }
        } else {
            pm_uw_op remainder[PM_UNWIND_MAX_SLOTS]; size_t count=0;
            int found=epilog(image,selected,pc,&selected_record,remainder,&count);
            if (found<0) return pm_uw_fail(error,error_capacity,"unsupported-or-invalid-epilog");
            proof.phase=found?PM_UNWIND_EPILOG:
                offset==selected_record.prolog?PM_UNWIND_PROLOG:PM_UNWIND_BODY;
            const pm_uw_op *ops=found?remainder:selected_record.ops;
            if (!found) count=selected_record.count;
            for (size_t i=0;i<count;++i) {
                if (!apply(&ops[i],stack,&next,&proof))
                    return pm_uw_fail(error,error_capacity,"stack-truncated-during-unwind");
            }
        }
    }
    if (!stack_pop(stack,&next,&next.rip)) return pm_uw_fail(error,error_capacity,"stack-truncated-at-return");
    ++proof.stack_words_read;
    proof.stack_advance=next.gpr[4]-input->gpr[4];
    *output=next;
    *result=proof;
    return 1;
}
