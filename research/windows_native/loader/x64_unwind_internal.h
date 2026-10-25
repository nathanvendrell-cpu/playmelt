#ifndef PLAYMELT_X64_UNWIND_INTERNAL_H
#define PLAYMELT_X64_UNWIND_INTERNAL_H
/* Private shared implementation: ONE metadata validator is consumed by the
 * pure unwinder and the opt-in loader, without introducing a new link dependency.
 * No Windows execution/exception dispatch, allocation, or OS calls here. */
#include "x64_unwind.h"
#include <stdio.h>
#include <string.h>

typedef struct pm_uw_op {
    uint64_t amount;
    uint8_t code_offset, reg;
    int push;
} pm_uw_op;

typedef struct pm_uw_record {
    uint8_t prolog;
    size_t count, encoded_size;
    pm_uw_op ops[PM_UNWIND_MAX_SLOTS];
} pm_uw_record;

static inline int pm_uw_fail(char *error,size_t cap,const char *message) {
    if (error && cap) snprintf(error,cap,"%s",message);
    return 0;
}
static inline uint16_t pm_uw_read16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | (uint16_t)p[1]<<8);
}
static inline uint32_t pm_uw_read32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}
static inline uint64_t pm_uw_read64(const uint8_t *p) {
    return (uint64_t)pm_uw_read32(p) | (uint64_t)pm_uw_read32(p+4)<<32;
}
static inline int pm_uw_nonvolatile(unsigned reg) {
    return reg==3 || reg==5 || reg==6 || reg==7 || (reg>=12 && reg<=15);
}
static inline const uint8_t *pm_uw_span(const pm_unwind_image *image,uint32_t rva,size_t bytes) {
    return rva<=image->size && bytes<=image->size-rva ? image->bytes+rva : NULL;
}

static inline int pm_uw_parse_record(const pm_unwind_image *image,const pm_runtime_function *function,
    pm_uw_record *record,char *error,size_t cap) {
    const uint8_t *p=pm_uw_span(image,function->unwind_rva,4);
    if (!p || !function->unwind_rva || function->unwind_rva%4)
        return pm_uw_fail(error,cap,"invalid-unwind-rva");
    if ((p[0]&7)!=1) return pm_uw_fail(error,cap,"unsupported-unwind-version");
    if (p[0]>>3) return pm_uw_fail(error,cap,"unsupported-unwind-flags-or-chain");
    if (p[3]) return pm_uw_fail(error,cap,"unsupported-frame-register");
    unsigned slots=p[2];
    if (slots>PM_UNWIND_MAX_SLOTS || p[1]>function->end_rva-function->begin_rva)
        return pm_uw_fail(error,cap,"invalid-unwind-count-or-prolog");
    if (!pm_uw_span(image,function->unwind_rva,4+2*((slots+1)&~1u)))
        return pm_uw_fail(error,cap,"truncated-unwind-slots");
    memset(record,0,sizeof *record);
    record->prolog=p[1];
    record->encoded_size=4+2*((slots+1)&~1u);
    unsigned last=(unsigned)record->prolog+1;
    uint64_t total=0;
    int seen_push=0;
    for (unsigned slot=0;slot<slots;) {
        const uint8_t *code=p+4+2*slot;
        unsigned opcode=code[1]&15, info=code[1]>>4;
        if (!code[0] || code[0]>record->prolog || code[0]>=last)
            return pm_uw_fail(error,cap,"invalid-unwind-code-offset");
        last=code[0];
        pm_uw_op op={0}; op.code_offset=code[0];
        unsigned consumed=1;
        if (opcode==0) {
            if (!pm_uw_nonvolatile(info)) return pm_uw_fail(error,cap,"unsupported-push-register");
            op.push=1; op.reg=(uint8_t)info; op.amount=8;
        } else if (opcode==2) {
            op.amount=info*8+8;
        } else if (opcode==1) {
            if (info>1) return pm_uw_fail(error,cap,"invalid-alloc-large-opinfo");
            consumed=info==0?2:3;
            if (slot+consumed>slots) return pm_uw_fail(error,cap,"truncated-alloc-large");
            op.amount=info==0?(uint64_t)pm_uw_read16(code+2)*8:pm_uw_read32(code+2);
            if (!op.amount || op.amount%8) return pm_uw_fail(error,cap,"invalid-alloc-large-size");
            if ((info==0 && op.amount<136) || (info==1 && op.amount<524288))
                return pm_uw_fail(error,cap,"nonminimal-alloc-large-encoding");
        } else return pm_uw_fail(error,cap,"unsupported-unwind-opcode");
        if (!op.push && seen_push) return pm_uw_fail(error,cap,"invalid-push-order");
        if (op.push) seen_push=1;
        if (op.amount>PM_UNWIND_MAX_STACK-total)
            return pm_uw_fail(error,cap,"unwind-stack-budget-exceeded");
        total+=op.amount;
        record->ops[record->count++]=op;
        slot+=consumed; /* Operand slots are never interpreted as instructions. */
    }
    return 1;
}

static inline int pm_uw_validate_catalogue(const pm_unwind_image *image, uint32_t pc,
    const pm_runtime_function **selected, pm_uw_record *selected_record,
    char *error, size_t cap) {
    if (!image || !image->bytes || !image->size || image->size>PM_UNWIND_MAX_IMAGE ||
        image->address>UINT64_MAX-image->size || image->function_count>PM_UNWIND_MAX_FUNCTIONS ||
        (image->function_count && !image->functions))
        return pm_uw_fail(error,cap,"invalid-view-or-argument");
    if (image->catalog_complete!=1 || (image->allow_leaf!=0 && image->allow_leaf!=1))
        return pm_uw_fail(error,cap,"incomplete-or-invalid-catalogue");
    if (selected) *selected=NULL;
    uint32_t previous_end=0;
    for (size_t i=0;i<image->function_count;++i) {
        const pm_runtime_function *function=&image->functions[i];
        if (function->begin_rva>=function->end_rva || function->end_rva>image->size ||
            (i && function->begin_rva<previous_end))
            return pm_uw_fail(error,cap,"invalid-or-overlapping-function-table");
        previous_end=function->end_rva;
        pm_uw_record record;
        if (!pm_uw_parse_record(image,function,&record,error,cap)) return 0;
        if (selected && selected_record && pc>=function->begin_rva && pc<function->end_rva) {
            *selected=function; *selected_record=record;
        }
    }
    return 1;
}

#endif
