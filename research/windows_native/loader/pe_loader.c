/* Reference: Microsoft PE Format, .idata and base relocations.
 * https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
 * No packed-struct casts: every untrusted integer is bounded and decoded LE.
 */
#include "pe_loader.h"
#include "x64_unwind_internal.h"

#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define PM_MAX_FILE (16u * 1024u * 1024u)
#define PM_MAX_IMAGE (64u * 1024u * 1024u)
#define PM_MAX_SECTIONS 32u
#define PM_MAX_IMPORTS 1024u
#define PM_MAX_DLLS 64u
#define PM_MAX_RELOCS 4096u
#define PM_MAX_BLOCKS 256u
#define PM_MAX_EXPORTS 1024u
#define PM_MAX_EXPORT_NAMES 1024u
#define PM_MAX_EXPORT_STRINGS (128u * 1024u)
#define PM_SCN_EXECUTE 0x20000000u
#define PM_SCN_READ 0x40000000u
#define PM_SCN_WRITE 0x80000000u

typedef struct {
    uint32_t rva, extent, raw_size, raw_offset, flags;
} pm_section;

typedef struct {
    uint32_t rva, forwarder_offset;
    pm_pe_export_kind kind; /* 0 is an ordinal hole, never returned as an address. */
    int executable, writable;
} pm_export_entry;
typedef struct { uint32_t name_offset, index; } pm_export_name;
struct pm_pe_export_catalog {
    const void *bound_mapping;
    size_t bound_mapping_size;
    uint32_t image_size, base, count, name_count, string_bytes;
    pm_export_entry entries[PM_MAX_EXPORTS];
    pm_export_name names[PM_MAX_EXPORT_NAMES];
    char strings[PM_MAX_EXPORT_STRINGS];
};

struct pm_pe_synthetic_dll_control {
    const pm_pe_image *owner;
    const void *mapping;
    size_t mapping_size;
    uint32_t entrypoint_rva;
    pthread_t thread;
    pm_pe_dll_state state;
};

typedef struct { uint32_t rva, bytes; unsigned kind; } pm_unwind_range;
struct pm_pe_unwind_control {
    const pm_pe_image *owner;
    const void *mapping;
    size_t mapping_size;
    uint32_t entrypoint_rva;
    pthread_t thread;
    pm_unwind_image view;
    uint8_t *projection;
    pm_runtime_function functions[PM_UNWIND_MAX_FUNCTIONS];
    pm_unwind_range ranges[1+2*PM_UNWIND_MAX_FUNCTIONS];
    size_t range_count;
};

struct pm_pe_lifetime {
    const pm_pe_image *owner;
    const void *mapping;
    size_t mapping_size;
    uint32_t entrypoint_rva;
    const struct pm_pe_export_catalog *exports;
    const struct pm_pe_synthetic_dll_control *dll;
    const struct pm_pe_unwind_control *unwind;
    pthread_t thread;
    int ready, is_dll, declared;
    uint32_t incoming;
    size_t dependency_count;
    struct pm_pe_lifetime *dependencies[PM_PE_DEPENDENCY_LIMIT];
};

/* Read-only export inspection remains allowed on a different serialized HOST
 * thread; ownership mutation explicitly requests the loading-thread guard. */
static struct pm_pe_lifetime *image_lifetime(const pm_pe_image *image,int owner_thread) {
    if (!image || !image->lifetime) return NULL;
    struct pm_pe_lifetime *c=image->lifetime;
    if (c->owner!=image || !image->mapping || c->mapping!=image->mapping ||
        c->mapping_size!=image->mapping_size || c->entrypoint_rva!=image->entrypoint_rva ||
        c->exports!=image->exports || c->dll!=image->synthetic_dll || c->unwind!=image->synthetic_unwind ||
        (owner_thread && !pthread_equal(c->thread,pthread_self()))) return NULL;
    return c;
}

typedef struct {
    const uint8_t *bytes;
    size_t size, page_size, mapping_size;
    uint64_t image_base;
    uint32_t image_size, header_size, entry, section_count;
    uint32_t dirs[16][2];
    pm_section sections[PM_MAX_SECTIONS];
    uint8_t *mapping, *permissions;
    struct pm_pe_export_catalog *exports;
    struct pm_pe_unwind_control *unwind;
    int synthetic_dll, synthetic_unwind, is_dll;
    char *error;
    size_t error_cap;
} pm_loader;

static int fail(pm_loader *p, const char *message) {
    if (p->error != NULL && p->error_cap != 0)
        (void)snprintf(p->error, p->error_cap, "%s", message);
    return 0;
}

static int within(size_t offset, size_t count, size_t limit) {
    return offset <= limit && count <= limit - offset;
}

static uint16_t u16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}
static uint32_t u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t u64(const uint8_t *p) {
    return (uint64_t)u32(p) | ((uint64_t)u32(p + 4) << 32);
}
static void put64(uint8_t *p, uint64_t value) {
    for (unsigned i = 0; i < 8; ++i) p[i] = (uint8_t)(value >> (8u * i));
}
static int power_of_two(uint32_t value) {
    return value != 0 && (value & (value - 1u)) == 0;
}

/* Returns one unambiguous section; headers are intentionally excluded here. */
static const pm_section *section_for(pm_loader *p, uint32_t rva, size_t size) {
    if (!within(rva, size, p->image_size)) return NULL;
    for (uint32_t i = 0; i < p->section_count; ++i) {
        const pm_section *s = &p->sections[i];
        if (rva >= s->rva && within((size_t)(rva - s->rva), size, s->extent)) return s;
    }
    return NULL;
}

/* Metadata is always read from original immutable file bytes, never from the
 * relocated image or IAT. Writes cannot alter future parser control data. */
static const uint8_t *raw_at(pm_loader *p, uint32_t rva, size_t size) {
    const pm_section *s = section_for(p, rva, size);
    if (s == NULL || !within(rva - s->rva, size, s->raw_size)) return NULL;
    size_t offset = (size_t)s->raw_offset + (rva - s->rva);
    return within(offset, size, p->size) ? p->bytes + offset : NULL;
}

static const char *ascii_at(pm_loader *p, uint32_t rva, size_t max_length) {
    const pm_section *s = section_for(p, rva, 1);
    if (s == NULL || rva - s->rva >= s->raw_size) return NULL;
    size_t remaining = s->raw_size - (rva - s->rva);
    size_t limit = remaining < max_length + 1 ? remaining : max_length + 1;
    const uint8_t *text = raw_at(p, rva, limit);
    if (text == NULL) return NULL;
    for (size_t i = 0; i < limit; ++i) {
        if (text[i] == 0) return i != 0 ? (const char *)text : NULL;
        if (text[i] < 32 || text[i] > 126) return NULL;
    }
    return NULL;
}

static int mark_permissions(pm_loader *p, uint32_t rva, uint32_t size, int protection) {
    if (size == 0) return 1;
    size_t first = rva / p->page_size;
    size_t last = ((size_t)rva + size - 1) / p->page_size;
    for (size_t page = first; page <= last; ++page) {
        unsigned combined = p->permissions[page] | (unsigned)protection;
        if ((combined & PROT_WRITE) && (combined & PROT_EXEC))
            return fail(p, "unsupported-layout: writable and executable sections share a host page");
        p->permissions[page] = (uint8_t)combined;
    }
    return 1;
}

static int parse_headers(pm_loader *p) {
    if (p->bytes == NULL || p->size < 64 || p->size > PM_MAX_FILE)
        return fail(p, "file-size-limit: expected 64 bytes..16 MiB of immutable fixture bytes");
    if (p->bytes[0] != 'M' || p->bytes[1] != 'Z') return fail(p, "invalid-header: missing MZ");
    uint32_t pe = u32(p->bytes + 0x3c);
    if (pe < 64 || pe > 1024u * 1024u || !within(pe, 24, p->size))
        return fail(p, "invalid-header: PE offset outside bounded file");
    const uint8_t *coff = p->bytes + pe + 4;
    if (memcmp(p->bytes + pe, "PE\0\0", 4) != 0) return fail(p, "invalid-header: missing PE signature");
    if (u16(coff) != 0x8664) return fail(p, "unsupported-machine: only AMD64 images are accepted");
    p->section_count = u16(coff + 2);
    uint16_t opt_size = u16(coff + 16), attributes = u16(coff + 18);
    if (p->section_count == 0 || p->section_count > PM_MAX_SECTIONS)
        return fail(p, "section-limit: expected 1..32 sections");
    if (!(attributes & 0x0002)) return fail(p, "unsupported-image: executable-image flag is absent");
    if (attributes & 0x0001) return fail(p, "unsupported-image: relocation-stripped image");
    size_t opt_offset = (size_t)pe + 24;
    if (opt_size < 112 || opt_size > 4096 || !within(opt_offset, opt_size, p->size))
        return fail(p, "invalid-header: truncated optional header");
    const uint8_t *opt = p->bytes + opt_offset;
    if (u16(opt) != 0x20b) return fail(p, "unsupported-format: only PE32+ is accepted");
    uint32_t section_align = u32(opt + 32), file_align = u32(opt + 36);
    if (!power_of_two(section_align) || section_align < 0x1000 || section_align > PM_MAX_IMAGE ||
        !power_of_two(file_align) || file_align < 512 || file_align > 65536 || file_align > section_align)
        return fail(p, "unsupported-alignment: invalid section/file alignment");
    p->image_base = u64(opt + 24); p->entry = u32(opt + 16);
    int is_dll = (attributes & 0x2000) != 0;
    p->is_dll=is_dll;
    if (p->synthetic_unwind && (is_dll || p->entry==0))
        return fail(p,"invalid-synthetic-unwind: EXE with nonzero entry required");
    if (p->synthetic_dll) {
        if (!is_dll || p->entry == 0)
            return fail(p, "invalid-synthetic-dll: DLL flag and nonzero initialization entry required");
    } else if (is_dll && p->entry != 0) return fail(p, "unsupported-dll: nonzero DLL initialization entry point");
    p->image_size = u32(opt + 56); p->header_size = u32(opt + 60);
    if (p->synthetic_unwind && p->image_size>PM_UNWIND_MAX_IMAGE)
        return fail(p,"unwind-image-limit: maximum 1 MiB");
    if (p->image_size == 0 || p->image_size > PM_MAX_IMAGE || p->image_size % section_align != 0 ||
        p->header_size == 0 || p->header_size > 1024u * 1024u || p->header_size % file_align != 0 ||
        p->header_size > p->image_size || p->header_size > p->size ||
        p->image_base > UINT64_MAX - p->image_size || p->image_base % 65536u != 0)
        return fail(p, "invalid-header: bounded image/header/base constraints failed");
    uint16_t subsystem = u16(opt + 68), dll_flags = u16(opt + 70);
    if (subsystem != 2 && subsystem != 3) return fail(p, "unsupported-subsystem: only Windows GUI/console fixtures are accepted");
    if (dll_flags & 0x4000) return fail(p, "unsupported-cfg: control-flow-guard setup is not implemented");
    uint32_t dirs = u32(opt + 108);
    if (dirs > 16 || !within(112, (size_t)dirs * 8, opt_size))
        return fail(p, "invalid-header: data directories exceed optional header");
    size_t section_offset = opt_offset + opt_size;
    if (!within(section_offset, (size_t)p->section_count * 40, p->header_size))
        return fail(p, "invalid-header: section table exceeds SizeOfHeaders");
    for (uint32_t i = 0; i < p->section_count; ++i) {
        const uint8_t *entry = p->bytes + section_offset + (size_t)i * 40;
        pm_section *s = &p->sections[i];
        uint32_t virtual_size = u32(entry + 8);
        s->rva = u32(entry + 12); s->raw_size = u32(entry + 16); s->raw_offset = u32(entry + 20);
        s->flags = u32(entry + 36);
        s->extent = virtual_size > s->raw_size ? virtual_size : s->raw_size;
        if (s->extent == 0 || s->rva < p->header_size || s->rva % section_align != 0 ||
            !within(s->rva, s->extent, p->image_size) ||
            (s->raw_size && (s->raw_offset < p->header_size || s->raw_offset % file_align != 0 ||
                            s->raw_size % file_align != 0 || !within(s->raw_offset, s->raw_size, p->size))))
            return fail(p, "invalid-section: alignment/range outside file or image");
        if ((s->flags & PM_SCN_WRITE) && (s->flags & PM_SCN_EXECUTE))
            return fail(p, "unsupported-wx: a section requests write and execute");
        for (uint32_t j = 0; j < i; ++j) {
            const pm_section *other = &p->sections[j];
            if (s->rva < (uint64_t)other->rva + other->extent && other->rva < (uint64_t)s->rva + s->extent)
                return fail(p, "ambiguous-layout: overlapping virtual sections");
            if (s->raw_size && other->raw_size && s->raw_offset < (uint64_t)other->raw_offset + other->raw_size &&
                other->raw_offset < (uint64_t)s->raw_offset + s->raw_size)
                return fail(p, "ambiguous-layout: overlapping file sections");
        }
    }
    static const char *unsupported[16] = {
        NULL, NULL, "unsupported-directory: resources",
        "unsupported-directory: exception/unwind", "unsupported-directory: certificates", NULL,
        "unsupported-directory: debug", "unsupported-directory: architecture",
        "unsupported-directory: global-pointer", "unsupported-directory: TLS",
        "unsupported-directory: load-config", "unsupported-directory: bound-imports", NULL,
        "unsupported-directory: delay-import", "unsupported-directory: CLR", "unsupported-directory: reserved"
    };
    for (uint32_t i = 0; i < dirs; ++i) {
        uint32_t rva = u32(opt + 112 + i * 8), size = u32(opt + 116 + i * 8);
        if ((rva == 0) != (size == 0)) return fail(p, "invalid-directory: incomplete address/size pair");
        if (rva != 0) {
            if (unsupported[i] != NULL && !(i==3 && p->synthetic_unwind)) return fail(p, unsupported[i]);
            if (raw_at(p, rva, size) == NULL) return fail(p, "invalid-directory: metadata is not file-backed in one section");
        }
        p->dirs[i][0] = rva; p->dirs[i][1] = size;
    }
    if (p->synthetic_unwind && !p->dirs[3][0])
        return fail(p,"invalid-synthetic-unwind: nonempty directory 3 required");
    if (!is_dll || p->synthetic_dll) {
        const pm_section *entry_section = section_for(p, p->entry, 1);
        if (p->entry == 0 || entry_section == NULL || !(entry_section->flags & PM_SCN_EXECUTE) || raw_at(p, p->entry, 1) == NULL)
            return fail(p, "invalid-entry: entry point must be file-backed in an executable section");
    }
    long page = sysconf(_SC_PAGESIZE);
    if (page < 4096 || page > 65536 || !power_of_two((uint32_t)page))
        return fail(p, "unsupported-host: unexpected host page size");
    p->page_size = (size_t)page;
    p->mapping_size = ((size_t)p->image_size + p->page_size - 1) & ~(p->page_size - 1);
    p->permissions = calloc(p->mapping_size / p->page_size, 1);
    if (p->permissions == NULL) return fail(p, "allocation-failed: page permission plan");
    if (!mark_permissions(p, 0, p->header_size, PROT_READ)) return 0;
    for (uint32_t i = 0; i < p->section_count; ++i) {
        const pm_section *s = &p->sections[i];
        int protection = 0;
        if (s->flags & PM_SCN_READ) protection |= PROT_READ;
        if (s->flags & PM_SCN_WRITE) protection |= PROT_WRITE | PROT_READ;
        if (s->flags & PM_SCN_EXECUTE) protection |= PROT_EXEC | PROT_READ;
        if (!mark_permissions(p, s->rva, s->extent, protection)) return 0;
    }
    return 1;
}

static void free_unwind(struct pm_pe_unwind_control *control) {
    if (control) { free(control->projection); free(control); }
}

/* kind 1=.pdata, 2=recorded function code, 3=.xdata. Shared .xdata records
 * are allowed only as an identical range; partial or cross-kind overlap fails. */
static int add_unwind_range(pm_loader *p,uint32_t rva,uint32_t bytes,unsigned kind) {
    struct pm_pe_unwind_control *c=p->unwind;
    const pm_section *s=section_for(p,rva,bytes);
    unsigned required=kind==2?(PM_SCN_READ|PM_SCN_EXECUTE):PM_SCN_READ;
    unsigned protection=kind==2?(PROT_READ|PROT_EXEC):PROT_READ;
    if (!bytes || !s || (s->flags&(PM_SCN_READ|PM_SCN_WRITE|PM_SCN_EXECUTE))!=required || !raw_at(p,rva,bytes))
        return fail(p,"invalid-unwind-section: immutable file-backed code/metadata required");
    size_t first=rva/p->page_size,last=((size_t)rva+bytes-1)/p->page_size;
    for (size_t page=first;page<=last;++page)
        if (p->permissions[page]!=protection)
            return fail(p,"invalid-unwind-pages: shared host page is not immutable R/RX");
    for (size_t i=0;i<c->range_count;++i) {
        const pm_unwind_range *other=&c->ranges[i];
        if (rva<(uint64_t)other->rva+other->bytes && other->rva<(uint64_t)rva+bytes) {
            if (kind==3 && other->kind==3 && rva==other->rva && bytes==other->bytes) return 1;
            return fail(p,"invalid-unwind-ranges: overlapping protected ranges");
        }
    }
    if (c->range_count>=1+2*PM_UNWIND_MAX_FUNCTIONS) return fail(p,"unwind-range-limit");
    c->ranges[c->range_count++]=(pm_unwind_range){rva,bytes,kind};
    return 1;
}

static int prepare_unwind(pm_loader *p) {
    if (!p->synthetic_unwind) return 1;
    uint32_t table=p->dirs[3][0],bytes=p->dirs[3][1];
    if (table%4 || !bytes || bytes%12 || bytes/12>PM_UNWIND_MAX_FUNCTIONS)
        return fail(p,"invalid-unwind-table: aligned 12-byte records required");
    struct pm_pe_unwind_control *c=calloc(1,sizeof *c);
    if (!c) return fail(p,"allocation-failed: unwind control");
    p->unwind=c;
    c->projection=calloc(p->image_size,1);
    if (!c->projection) return fail(p,"allocation-failed: unwind projection");
    c->view=(pm_unwind_image){c->projection,p->image_size,p->image_base,c->functions,bytes/12,1,0};
    if (!add_unwind_range(p,table,bytes,1)) return 0;
    const uint8_t *raw=raw_at(p,table,bytes);
    /* A temporary readable RVA projection lets the shared bounded validator
     * parse records; section/protection validation follows before any mapping. */
    for (uint32_t i=0;i<p->section_count;++i) {
        const pm_section *s=&p->sections[i];
        if (s->raw_size) memcpy(c->projection+s->rva,p->bytes+s->raw_offset,s->raw_size);
    }
    for (size_t i=0;i<c->view.function_count;++i) {
        c->functions[i]=(pm_runtime_function){u32(raw+12*i),u32(raw+12*i+4),u32(raw+12*i+8)};
    }
    if (!pm_uw_validate_catalogue(&c->view,0,NULL,NULL,p->error,p->error_cap)) return 0;
    int entry_covered=0;
    for (size_t i=0;i<c->view.function_count;++i) {
        const pm_runtime_function *f=&c->functions[i]; pm_uw_record record;
        if (!pm_uw_parse_record(&c->view,f,&record,p->error,p->error_cap)) return 0;
        if (!add_unwind_range(p,f->begin_rva,f->end_rva-f->begin_rva,2) ||
            !add_unwind_range(p,f->unwind_rva,(uint32_t)record.encoded_size,3)) return 0;
        if (p->entry>=f->begin_rva && p->entry<f->end_rva) entry_covered=1;
    }
    if (!entry_covered) return fail(p,"invalid-unwind-entry: EXE entry is not catalogued");
    return 1;
}

static int unwind_write_allowed(pm_loader *p,uint32_t rva,size_t bytes) {
    if (!p->unwind) return 1;
    for (size_t i=0;i<p->unwind->range_count;++i) {
        const pm_unwind_range *r=&p->unwind->ranges[i];
        if (rva<(uint64_t)r->rva+r->bytes && r->rva<(uint64_t)rva+bytes)
            return fail(p,"unsupported-unwind-fixup: write overlaps protected code/metadata");
    }
    return 1;
}

static int finalize_unwind(pm_loader *p) {
    struct pm_pe_unwind_control *c=p->unwind;
    if (!c) return 1;
    memset(c->projection,0,c->view.size);
    for (size_t i=0;i<c->range_count;++i) {
        const pm_unwind_range *r=&c->ranges[i];
        const uint8_t *raw=raw_at(p,r->rva,r->bytes);
        if (!raw || memcmp(raw,p->mapping+r->rva,r->bytes))
            return fail(p,"unwind-snapshot-mismatch: protected mapped bytes changed");
        memcpy(c->projection+r->rva,p->mapping+r->rva,r->bytes);
    }
    /* Catalogue provenance is the ACTUAL post-fixup mapping, not a parallel
     * source-maintained table. Protected .pdata was compared above first. */
    const uint8_t *table=p->mapping+p->dirs[3][0];
    for (size_t i=0;i<c->view.function_count;++i)
        c->functions[i]=(pm_runtime_function){u32(table+12*i),u32(table+12*i+4),u32(table+12*i+8)};
    c->view.address=(uintptr_t)p->mapping;
    return pm_uw_validate_catalogue(&c->view,0,NULL,NULL,p->error,p->error_cap);
}

static int export_string(pm_loader *p, const char *text, uint32_t *offset) {
    size_t size = strlen(text) + 1;
    struct pm_pe_export_catalog *catalog = p->exports;
    if (!within(catalog->string_bytes, size, PM_MAX_EXPORT_STRINGS))
        return fail(p, "export-limit: strings exceed 128 KiB");
    *offset = catalog->string_bytes;
    memcpy(catalog->strings + catalog->string_bytes, text, size);
    catalog->string_bytes += (uint32_t)size;
    return 1;
}

/* Descriptive grammar only. Module identifiers are not paths. Splitting at the
 * last dot permits OTHER.dll.Name; no file is opened and no target is resolved. */
static int valid_forwarder(const char *text) {
    const char *dot = strrchr(text, '.');
    if (dot == NULL || dot == text || dot[1] == '\0' || text[0] == '.' || dot[-1] == '.') return 0;
    for (const char *c = text; c < dot; ++c) {
        int allowed = (*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') ||
                      (*c >= '0' && *c <= '9') || *c == '_' || *c == '-' || *c == '.';
        if (!allowed || (*c == '.' && c + 1 < dot && c[1] == '.')) return 0;
    }
    if (dot[1] == '#') {
        const char *digits = dot + 2;
        uint64_t ordinal = 0;
        if (*digits == '\0') return 0;
        for (; *digits; ++digits) {
            if (*digits < '0' || *digits > '9') return 0;
            ordinal = ordinal * 10 + (unsigned)(*digits - '0');
            if (ordinal > UINT32_MAX) return 0;
        }
    }
    return 1;
}

static int ranges_overlap(uint32_t a, uint32_t asize, uint32_t b, uint32_t bsize) {
    return asize && bsize && (uint64_t)a < (uint64_t)b + bsize && (uint64_t)b < (uint64_t)a + asize;
}

static int parse_exports(pm_loader *p) {
    uint32_t start = p->dirs[0][0], size = p->dirs[0][1];
    if (start == 0) return 1;
    const uint8_t *header = raw_at(p, start, 40);
    if (size < 40 || header == NULL) return fail(p, "invalid-exports: truncated directory");
    if (u32(header) != 0) return fail(p, "invalid-exports: reserved flags are nonzero");
    uint32_t dll_rva = u32(header + 12), base = u32(header + 16), count = u32(header + 20);
    uint32_t names = u32(header + 24), eat = u32(header + 28), npt = u32(header + 32), ord = u32(header + 36);
    if (count == 0 || count > PM_MAX_EXPORTS || names > PM_MAX_EXPORT_NAMES)
        return fail(p, "export-limit: expected 1..1024 addresses and at most 1024 names");
    if ((uint64_t)base + count - 1 > UINT32_MAX)
        return fail(p, "invalid-exports: ordinal base overflows uint32");
    const char *dll = ascii_at(p, dll_rva, 128);
    if (dll == NULL) return fail(p, "invalid-exports: module name is not bounded printable ASCII");
    const uint8_t *addresses = raw_at(p, eat, (size_t)count * 4);
    const uint8_t *name_table = names ? raw_at(p, npt, (size_t)names * 4) : NULL;
    const uint8_t *ord_table = names ? raw_at(p, ord, (size_t)names * 2) : NULL;
    if (addresses == NULL || (names && (name_table == NULL || ord_table == NULL)))
        return fail(p, "invalid-exports: unbacked address/name/ordinal table");
    uint32_t ranges[4][2] = {{start, 40}, {eat, count * 4}, {npt, names * 4}, {ord, names * 2}};
    for (unsigned i = 0; i < 4; ++i)
        for (unsigned j = 0; j < i; ++j)
            if (ranges_overlap(ranges[i][0], ranges[i][1], ranges[j][0], ranges[j][1]))
                return fail(p, "invalid-exports: overlapping structural tables");
    p->exports = calloc(1, sizeof(*p->exports));
    if (p->exports == NULL) return fail(p, "allocation-failed: export catalogue");
    struct pm_pe_export_catalog *catalog = p->exports;
    catalog->base = base; catalog->count = count; catalog->name_count = names;
    catalog->image_size = p->image_size;
    uint32_t unused_module_offset = 0;
    if (!export_string(p, dll, &unused_module_offset)) return 0;
    for (uint32_t i = 0; i < count; ++i) {
        pm_export_entry *entry = &catalog->entries[i];
        entry->rva = u32(addresses + (size_t)i * 4);
        if (entry->rva == 0) continue; /* Valid ordinal hole; lookup will refuse. */
        if (entry->rva >= start && (uint64_t)entry->rva < (uint64_t)start + size) {
            const char *forwarder = ascii_at(p, entry->rva, 512);
            if (forwarder == NULL || !within(entry->rva - start, strlen(forwarder) + 1, size))
                return fail(p, "invalid-exports: truncated or unbounded forwarder");
            if (!valid_forwarder(forwarder)) return fail(p, "invalid-exports: malformed forwarder description");
            entry->kind = PM_PE_EXPORT_FORWARDER;
            if (!export_string(p, forwarder, &entry->forwarder_offset)) return 0;
        } else {
            const pm_section *section = section_for(p, entry->rva, 1);
            if (section == NULL || !(p->permissions[entry->rva / p->page_size] & PROT_READ))
                return fail(p, "invalid-exports: direct target is not in a readable mapped section");
            int protection = p->permissions[entry->rva / p->page_size];
            entry->executable = (protection & PROT_EXEC) != 0;
            entry->writable = (protection & PROT_WRITE) != 0;
            if ((entry->executable && entry->writable) || (entry->executable && raw_at(p, entry->rva, 1) == NULL))
                return fail(p, "invalid-exports: executable target is writable or unbacked");
            entry->kind = PM_PE_EXPORT_DIRECT;
        }
    }
    const char *previous_name = NULL;
    for (uint32_t i = 0; i < names; ++i) {
        uint32_t name_rva = u32(name_table + (size_t)i * 4);
        uint32_t index = u16(ord_table + (size_t)i * 2);
        const char *name = ascii_at(p, name_rva, 256);
        if (name == NULL) return fail(p, "invalid-exports: name is not bounded printable ASCII");
        if (index >= count || catalog->entries[index].kind == 0)
            return fail(p, "invalid-exports: name refers to an invalid index or ordinal hole");
        if (previous_name != NULL && strcmp(previous_name, name) >= 0)
            return fail(p, "invalid-exports: names are not strictly sorted or are duplicated");
        previous_name = name;
        catalog->names[i].index = index;
        if (!export_string(p, name, &catalog->names[i].name_offset)) return 0;
    }
    return 1;
}

static int relocate(pm_loader *p) {
    uint64_t actual = (uint64_t)(uintptr_t)p->mapping;
    uint32_t start = p->dirs[5][0], total = p->dirs[5][1];
    if (start == 0) return actual == p->image_base ? 1 : fail(p, "missing-relocations: image moved from preferred base");
    uint32_t cursor = 0, blocks = 0, entries = 0, applied = 0;
    uint32_t targets[PM_MAX_RELOCS];
    while (cursor < total) {
        if (++blocks > PM_MAX_BLOCKS || !within(cursor, 8, total))
            return fail(p, "invalid-relocations: block count or truncated header");
        const uint8_t *header = raw_at(p, start + cursor, 8);
        if (header == NULL) return fail(p, "invalid-relocations: unmapped block header");
        uint32_t page_rva = u32(header), block_size = u32(header + 4);
        if (page_rva % 4096u != 0 || block_size < 8 || block_size % 4u != 0 || !within(cursor, block_size, total))
            return fail(p, "invalid-relocations: block size/page alignment");
        for (uint32_t item = 8; item < block_size; item += 2) {
            if (++entries > PM_MAX_RELOCS) return fail(p, "relocation-limit: more than 4096 entries");
            const uint8_t *encoded = raw_at(p, start + cursor + item, 2);
            if (encoded == NULL) return fail(p, "invalid-relocations: unbacked entry");
            uint16_t value = u16(encoded), type = value >> 12;
            if (type == 0) continue;
            if (type != 10) return fail(p, "unsupported-relocation: only ABSOLUTE and DIR64");
            uint64_t target64 = (uint64_t)page_rva + (value & 0xfffu);
            if (target64 > UINT32_MAX || raw_at(p, (uint32_t)target64, 8) == NULL)
                return fail(p, "invalid-relocations: DIR64 target outside file-backed section");
            uint32_t target = (uint32_t)target64;
            if (!unwind_write_allowed(p,target,8)) return 0;
            for (uint32_t j = 0; j < applied; ++j)
                if (target < (uint64_t)targets[j] + 8 && targets[j] < (uint64_t)target + 8)
                    return fail(p, "invalid-relocations: duplicate or overlapping DIR64 target");
            targets[applied++] = target;
            uint64_t original = u64(p->mapping + target), changed;
            if (actual >= p->image_base) {
                uint64_t delta = actual - p->image_base;
                if (original > UINT64_MAX - delta) return fail(p, "invalid-relocations: DIR64 overflow");
                changed = original + delta;
            } else {
                uint64_t delta = p->image_base - actual;
                if (original < delta) return fail(p, "invalid-relocations: DIR64 underflow");
                changed = original - delta;
            }
            put64(p->mapping + target, changed);
        }
        cursor += block_size;
    }
    return 1;
}

static int bind_imports(pm_loader *p, pm_import_resolver resolver, void *context) {
    uint32_t start = p->dirs[1][0], total = p->dirs[1][1];
    if (start == 0) return 1;
    uint32_t symbol_count = 0, slot_count = 0, slots[PM_MAX_IMPORTS + PM_MAX_DLLS];
    for (uint32_t dll_index = 0; dll_index <= PM_MAX_DLLS; ++dll_index) {
        size_t offset = (size_t)dll_index * 20;
        if (!within(offset, 20, total)) return fail(p, "invalid-imports: missing descriptor terminator");
        const uint8_t *d = raw_at(p, start + (uint32_t)offset, 20);
        if (d == NULL) return fail(p, "invalid-imports: unbacked descriptor");
        uint32_t lookup = u32(d), timestamp = u32(d + 4), forwarder = u32(d + 8), name = u32(d + 12), iat = u32(d + 16);
        if (!(lookup | timestamp | forwarder | name | iat)) return 1;
        if (dll_index == PM_MAX_DLLS) return fail(p, "import-limit: more than 64 DLL descriptors");
        if (timestamp || forwarder) return fail(p, "unsupported-imports: bound/forwarded descriptor");
        if (name == 0 || iat == 0 || iat % 8u != 0 || (lookup && lookup % 8u != 0))
            return fail(p, "invalid-imports: missing or unaligned name/IAT/lookup");
        const char *dll = ascii_at(p, name, 128);
        if (dll == NULL) return fail(p, "invalid-imports: DLL name is not bounded printable ASCII");
        if (lookup == 0) lookup = iat;
        for (uint32_t index = 0; index <= PM_MAX_IMPORTS; ++index) {
            uint64_t lookup64 = (uint64_t)lookup + (uint64_t)index * 8, iat64 = (uint64_t)iat + (uint64_t)index * 8;
            if (lookup64 > UINT32_MAX || iat64 > UINT32_MAX) return fail(p, "invalid-imports: thunk RVA overflow");
            const uint8_t *thunk = raw_at(p, (uint32_t)lookup64, 8);
            const pm_section *target_section = section_for(p, (uint32_t)iat64, 8);
            if (thunk == NULL || target_section == NULL || (target_section->flags & PM_SCN_EXECUTE) ||
                !(target_section->flags & (PM_SCN_READ | PM_SCN_WRITE)) ||
                raw_at(p, (uint32_t)iat64, 8) == NULL)
                return fail(p, "invalid-imports: lookup/IAT not file-backed, IAT is executable or unreadable");
            uint64_t value = u64(thunk);
            if (slot_count >= PM_MAX_IMPORTS + PM_MAX_DLLS) return fail(p, "import-limit: too many IAT slots");
            for (uint32_t j = 0; j < slot_count; ++j)
                if (slots[j] == (uint32_t)iat64) return fail(p, "invalid-imports: duplicate IAT slot");
            slots[slot_count++] = (uint32_t)iat64;
            if (!unwind_write_allowed(p,(uint32_t)iat64,8)) return 0;
            if (value == 0) { put64(p->mapping + (uint32_t)iat64, 0); break; }
            if (symbol_count >= PM_MAX_IMPORTS) return fail(p, "import-limit: more than 1024 named symbols");
            int by_ordinal = (value & (UINT64_C(1) << 63)) != 0;
            uint16_t ordinal = 0;
            const char *function = NULL;
            if (by_ordinal) {
                if (value & ~((UINT64_C(1) << 63) | UINT64_C(0xffff)))
                    return fail(p, "invalid-imports: reserved ordinal bits are nonzero");
                ordinal = (uint16_t)(value & 0xffffu);
            } else {
                if (value >= UINT64_C(0x80000000) || raw_at(p, (uint32_t)value, 2) == NULL)
                    return fail(p, "invalid-imports: hint/name RVA is invalid");
                function = ascii_at(p, (uint32_t)value + 2u, 256);
                if (function == NULL) return fail(p, "invalid-imports: symbol is not bounded printable ASCII");
            }
            ++symbol_count;
            uintptr_t address = 0;
            if (resolver == NULL || resolver(context, dll, function, ordinal, by_ordinal, &address) != 1 || address == 0)
                return fail(p, "unresolved-import: resolver refused dependency");
            put64(p->mapping + (uint32_t)iat64, (uint64_t)address);
        }
    }
    return fail(p, "invalid-imports: missing descriptor terminator");
}

static int protect_image(pm_loader *p) {
    size_t count = p->mapping_size / p->page_size;
    for (size_t first = 0; first < count;) {
        size_t next = first + 1;
        while (next < count && p->permissions[next] == p->permissions[first]) ++next;
        if (mprotect(p->mapping + first * p->page_size, (next - first) * p->page_size, p->permissions[first]) != 0)
            return fail(p, "protection-failed: host refused final W^X page permissions");
        first = next;
    }
    return 1;
}

static int load_image(const uint8_t *bytes, size_t size, pm_import_resolver resolver,
                       void *context, pm_pe_image *image, char *error, size_t error_cap,
                       int synthetic_dll,int synthetic_unwind) {
    pm_loader p = {0};
    p.bytes = bytes; p.size = size; p.error = error; p.error_cap = error_cap;
    p.synthetic_dll = synthetic_dll;
    p.synthetic_unwind = synthetic_unwind;
    if (error != NULL && error_cap) error[0] = '\0';
    if (image == NULL) return fail(&p, "invalid-argument: output image is null");
    if (image->mapping != NULL || image->mapping_size != 0 || image->entrypoint_rva != 0 || image->exports != NULL || image->synthetic_dll != NULL || image->synthetic_unwind != NULL || image->lifetime != NULL)
        return fail(&p, "invalid-argument: unload the previous image before reuse");
    int ok = parse_headers(&p) && parse_exports(&p) && prepare_unwind(&p);
    struct pm_pe_synthetic_dll_control *control = NULL;
    if (ok && synthetic_dll) {
        control = calloc(1, sizeof *control);
        if (control == NULL) ok = fail(&p, "allocation-failed: synthetic DLL lifecycle");
    }
    struct pm_pe_lifetime *lifetime=NULL;
    if (ok) {
        lifetime=calloc(1,sizeof *lifetime);
        if (!lifetime) ok=fail(&p,"allocation-failed: image lifetime control");
    }
    if (ok) {
        void *mapping = mmap(NULL, p.mapping_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (mapping == MAP_FAILED) ok = fail(&p, "allocation-failed: anonymous image mapping");
        else p.mapping = mapping;
    }
    if (ok) {
        memcpy(p.mapping, bytes, p.header_size);
        for (uint32_t i = 0; i < p.section_count; ++i) {
            const pm_section *s = &p.sections[i];
            if (s->raw_size) memcpy(p.mapping + s->rva, bytes + s->raw_offset, s->raw_size);
        }
        ok = relocate(&p) && bind_imports(&p, resolver, context) && finalize_unwind(&p) && protect_image(&p);
    }
    free(p.permissions);
    if (!ok) {
        free(p.exports);
        free(control);
        free_unwind(p.unwind);
        if (p.mapping != NULL && munmap(p.mapping, p.mapping_size) != 0) {
            image->mapping = p.mapping;
            image->mapping_size = p.mapping_size;
            image->entrypoint_rva = 0;
            lifetime->owner=image; lifetime->mapping=p.mapping;
            lifetime->mapping_size=p.mapping_size; lifetime->thread=pthread_self();
            lifetime->is_dll=p.is_dll; image->lifetime=lifetime;
            return fail(&p, "cleanup-failed: partial mapping retained; retry pm_pe_unload");
        }
        free(lifetime);
        return 0;
    }
    image->mapping = p.mapping;
    image->mapping_size = p.mapping_size;
    image->entrypoint_rva = p.entry;
    if (p.exports != NULL) {
        p.exports->bound_mapping = p.mapping;
        p.exports->bound_mapping_size = p.mapping_size;
    }
    image->exports = p.exports;
    if (p.unwind) {
        p.unwind->owner=image; p.unwind->mapping=p.mapping;
        p.unwind->mapping_size=p.mapping_size; p.unwind->entrypoint_rva=p.entry;
        p.unwind->thread=pthread_self(); image->synthetic_unwind=p.unwind;
    }
    if (control != NULL) {
        control->owner = image; control->mapping = p.mapping;
        control->mapping_size = p.mapping_size; control->entrypoint_rva = p.entry;
        control->thread = pthread_self(); control->state = PM_PE_DLL_READY;
        image->synthetic_dll = control;
    }
    lifetime->owner=image; lifetime->mapping=p.mapping; lifetime->mapping_size=p.mapping_size;
    lifetime->entrypoint_rva=p.entry; lifetime->exports=image->exports;
    lifetime->dll=image->synthetic_dll; lifetime->unwind=image->synthetic_unwind;
    lifetime->thread=pthread_self(); lifetime->ready=1; lifetime->is_dll=p.is_dll;
    image->lifetime=lifetime;
    return 1;
}

int pm_pe_load(const uint8_t *bytes, size_t size, pm_import_resolver resolver,
               void *context, pm_pe_image *image, char *error, size_t error_cap) {
    return load_image(bytes, size, resolver, context, image, error, error_cap, 0,0);
}

int pm_pe_load_synthetic_dll(const uint8_t *bytes, size_t size, pm_import_resolver resolver,
                            void *context, pm_pe_image *image, char *error, size_t error_cap) {
    return load_image(bytes, size, resolver, context, image, error, error_cap, 1,0);
}

int pm_pe_load_synthetic_unwind_exe(const uint8_t *bytes,size_t size,
    pm_import_resolver resolver,void *context,int complete_catalogue_attested,
    pm_pe_image *image,char *error,size_t error_cap) {
    if (complete_catalogue_attested!=1) {
        pm_loader p={0}; p.error=error; p.error_cap=error_cap;
        return fail(&p,"unwind-attestation-required: complete catalogue must be explicitly attested");
    }
    return load_image(bytes,size,resolver,context,image,error,error_cap,0,1);
}

static struct pm_pe_unwind_control *unwind_control(const pm_pe_image *image) {
    struct pm_pe_lifetime *life=image_lifetime(image,1);
    if (!life || !life->ready || !image->synthetic_unwind) return NULL;
    struct pm_pe_unwind_control *c=image->synthetic_unwind;
    if (c->owner!=image || c->mapping!=image->mapping || c->mapping_size!=image->mapping_size ||
        c->entrypoint_rva!=image->entrypoint_rva || !image->mapping ||
        !pthread_equal(c->thread,pthread_self())) return NULL;
    return c;
}

int pm_pe_unwind_view(const pm_pe_image *image,struct pm_unwind_image *output,
    char *error,size_t error_cap) {
    if (error && error_cap) error[0]=0;
    struct pm_pe_unwind_control *c=unwind_control(image);
    if (!c || !output) {
        pm_loader p={0}; p.error=error; p.error_cap=error_cap;
        return fail(&p,"unwind-view-unavailable: live original handle and loading thread required");
    }
    *output=c->view;
    return 1;
}

static struct pm_pe_synthetic_dll_control *dll_control(const pm_pe_image *image) {
    if (image == NULL || image->synthetic_dll == NULL) return NULL;
    struct pm_pe_synthetic_dll_control *control = image->synthetic_dll;
    if (control->owner != image || !pthread_equal(control->thread, pthread_self()) ||
        control->mapping != image->mapping || control->mapping_size != image->mapping_size ||
        control->entrypoint_rva != image->entrypoint_rva || image->mapping == NULL ||
        image->entrypoint_rva == 0 || image->entrypoint_rva >= image->mapping_size) return NULL;
    return control;
}

pm_pe_dll_state pm_pe_synthetic_dll_state(const pm_pe_image *image) {
    struct pm_pe_synthetic_dll_control *control = dll_control(image);
    struct pm_pe_lifetime *life=image_lifetime(image,1);
    return control && life && life->ready ? control->state : PM_PE_DLL_UNAVAILABLE;
}

/* Microsoft dynamic-load DllMain semantics, consulted 2026-10-25:
 * https://learn.microsoft.com/en-us/windows/win32/dlls/dllmain
 * FALSE from PROCESS_ATTACH receives PROCESS_DETACH; detach's BOOL is ignored.
 * No Windows exception dispatcher or host fault recovery is provided here. */
#if defined(__x86_64__)
typedef int32_t (__attribute__((ms_abi)) *pm_synthetic_dll_entry)(void *,uint32_t,void *);
/* Source-generated PE entries carry no Clang function-type metadata. Exempt
 * only this trampoline call; all other ASan/UBSan host instrumentation remains. */
__attribute__((no_sanitize("function")))
static int32_t call_synthetic_dll_entry(pm_synthetic_dll_entry entry,void *base,uint32_t reason) {
    return entry(base,reason,NULL);
}
#endif

static int notify_synthetic_dll(pm_pe_image *image, int attach, char *error, size_t error_cap) {
    pm_loader report = {0}; report.error = error; report.error_cap = error_cap;
    if (error != NULL && error_cap) error[0] = '\0';
    struct pm_pe_synthetic_dll_control *control = dll_control(image);
    struct pm_pe_lifetime *life=image_lifetime(image,1);
    if (control == NULL || !life || !life->ready) return fail(&report, "invalid-synthetic-dll: live original handle and loading thread required");
    if (life->incoming) return fail(&report,"dll-held: dependent EXE must unmap before notification");
    if (control->state != (attach ? PM_PE_DLL_READY : PM_PE_DLL_ATTACHED))
        return fail(&report, "invalid-dll-transition: duplicate, nested, or out-of-order notification");
#if defined(__x86_64__)
    pm_synthetic_dll_entry entry = (pm_synthetic_dll_entry)((uint8_t *)image->mapping + image->entrypoint_rva);
    if (attach) {
        control->state = PM_PE_DLL_ATTACHING;
        int32_t accepted = call_synthetic_dll_entry(entry,image->mapping,1);
        if (accepted) { control->state = PM_PE_DLL_ATTACHED; return 1; }
        control->state = PM_PE_DLL_DETACHING;
        (void)call_synthetic_dll_entry(entry,image->mapping,0);
        control->state = PM_PE_DLL_FAILED;
        return fail(&report, "dll-attach-failed: PROCESS_DETACH cleanup completed; unload the failed image");
    }
    control->state = PM_PE_DLL_DETACHING;
    (void)call_synthetic_dll_entry(entry,image->mapping,0);
    control->state = PM_PE_DLL_DETACHED;
    return 1;
#else
    return fail(&report, "unsupported-host: synthetic DllMain execution requires x86_64 Microsoft ABI");
#endif
}

int pm_pe_synthetic_dll_attach(pm_pe_image *image, char *error, size_t error_cap) {
    return notify_synthetic_dll(image, 1, error, error_cap);
}
int pm_pe_synthetic_dll_detach(pm_pe_image *image, char *error, size_t error_cap) {
    return notify_synthetic_dll(image, 0, error, error_cap);
}

/* Native ownership guards are not Windows loader reference semantics.
 * Microsoft distinction, consulted 2026-10-26:
 * https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-freelibrary
 * https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulehandleexa
 */
int pm_pe_hold_dependencies(pm_pe_image *client,const pm_pe_image *const *dependencies,
    size_t count,char *error,size_t error_cap) {
    pm_loader report={0}; report.error=error; report.error_cap=error_cap;
    if (error && error_cap) error[0]=0;
    struct pm_pe_lifetime *owner=image_lifetime(client,1);
    if (!owner || !owner->ready || owner->is_dll || owner->declared)
        return fail(&report,"invalid-dependency-client: original ready EXE with no prior declaration required");
    if (!dependencies || !count || count>PM_PE_DEPENDENCY_LIMIT)
        return fail(&report,"dependency-limit: expected 1..32 explicit DLL images");
    struct pm_pe_lifetime *validated[PM_PE_DEPENDENCY_LIMIT];
    for (size_t i=0;i<count;++i) {
        struct pm_pe_lifetime *dep=image_lifetime(dependencies[i],1);
        if (!dep || !dep->ready || !dep->is_dll || dep==owner ||
            dep->incoming>=PM_PE_CLIENT_HOLD_LIMIT)
            return fail(&report,"invalid-dependency: live original DLL or hold capacity unavailable");
        if (dep->dll) {
            struct pm_pe_synthetic_dll_control *dll=dll_control(dependencies[i]);
            if (!dll || dll->state!=PM_PE_DLL_ATTACHED)
                return fail(&report,"dependency-not-attached: synthetic DLL must be ATTACHED");
        }
        for (size_t j=0;j<i;++j) if (validated[j]==dep)
            return fail(&report,"duplicate-dependency: each DLL may occur only once");
        validated[i]=dep;
    }
    for (size_t i=0;i<count;++i) { ++validated[i]->incoming; owner->dependencies[i]=validated[i]; }
    owner->dependency_count=count; owner->declared=1;
    return 1;
}

static int dependency_links_valid(const struct pm_pe_lifetime *owner) {
    if (owner->dependency_count>PM_PE_DEPENDENCY_LIMIT ||
        (owner->dependency_count && (!owner->declared || owner->is_dll))) return 0;
    for (size_t i=0;i<owner->dependency_count;++i) {
        struct pm_pe_lifetime *dep=owner->dependencies[i];
        if (!dep || image_lifetime(dep->owner,1)!=dep || !dep->ready || !dep->is_dll ||
            !dep->incoming || dep->incoming>PM_PE_CLIENT_HOLD_LIMIT) return 0;
        if (dep->dll && dep->dll->state!=PM_PE_DLL_ATTACHED) return 0;
        for (size_t j=0;j<i;++j) if (owner->dependencies[j]==dep) return 0;
    }
    return 1;
}

int pm_pe_unload(pm_pe_image *image) {
    if (!image) return 1;
    if (!image->mapping && !image->mapping_size && !image->entrypoint_rva && !image->exports &&
        !image->synthetic_dll && !image->synthetic_unwind && !image->lifetime) return 1;
    struct pm_pe_lifetime *life=image_lifetime(image,1);
    if (!life || life->incoming || !dependency_links_valid(life)) return 0;
    /* Private unwind/DLL identity is already included in provenance. The raw
     * controls survive a failed unmap; ready-only public views cannot be used. */
    if (image->synthetic_unwind) {
        struct pm_pe_unwind_control *u=image->synthetic_unwind;
        if (u->owner!=image || u->mapping!=image->mapping || u->mapping_size!=image->mapping_size ||
            u->entrypoint_rva!=image->entrypoint_rva || !pthread_equal(u->thread,pthread_self())) return 0;
    }
    if (image->synthetic_dll) {
        struct pm_pe_synthetic_dll_control *dll=dll_control(image);
        if (!dll || (dll->state!=PM_PE_DLL_READY && dll->state!=PM_PE_DLL_DETACHED && dll->state!=PM_PE_DLL_FAILED)) return 0;
    }
    if (munmap(image->mapping,image->mapping_size)!=0) { life->ready=0; return 0; }
    /* All guards were validated before the OS call; these bounded decrements
     * cannot fail and happen ONLY after the client mapping is actually gone. */
    for (size_t i=0;i<life->dependency_count;++i) --life->dependencies[i]->incoming;
    free(image->exports); free(image->synthetic_dll); free_unwind(image->synthetic_unwind); free(life);
    *image=(pm_pe_image){0};
    return 1;
}

int pm_pe_find_export(const pm_pe_image *image, const char *name, uint32_t ordinal,
                      int by_ordinal, pm_pe_export *result, char *error, size_t error_cap) {
    pm_loader report = {0}; report.error = error; report.error_cap = error_cap;
    if (error != NULL && error_cap) error[0] = '\0';
    if (result == NULL) return fail(&report, "invalid-argument: export result is null");
    *result = (pm_pe_export){0};
    struct pm_pe_lifetime *life=image_lifetime(image,0);
    if (!life || !life->ready || image->exports == NULL)
        return fail(&report, "exports-unavailable: no live loaded catalogue");
    const struct pm_pe_export_catalog *catalog = image->exports;
    if (catalog->bound_mapping != image->mapping || catalog->bound_mapping_size != image->mapping_size)
        return fail(&report, "exports-unavailable: catalogue does not belong to this mapping");
    uint32_t index;
    if (by_ordinal == 1) {
        if (ordinal < catalog->base || ordinal - catalog->base >= catalog->count)
            return fail(&report, "export-not-found: ordinal outside catalogue");
        index = ordinal - catalog->base;
    } else if (by_ordinal == 0) {
        if (name == NULL) return fail(&report, "invalid-argument: export name is null");
        size_t length = 0;
        while (length <= 256 && name[length]) {
            if ((unsigned char)name[length] < 32 || (unsigned char)name[length] > 126)
                return fail(&report, "invalid-argument: export name must be printable ASCII");
            ++length;
        }
        if (length == 0 || length > 256) return fail(&report, "invalid-argument: export name length");
        uint32_t low = 0, high = catalog->name_count;
        while (low < high) {
            uint32_t middle = low + (high - low) / 2;
            int comparison = strcmp(catalog->strings + catalog->names[middle].name_offset, name);
            if (comparison < 0) low = middle + 1; else high = middle;
        }
        if (low == catalog->name_count || strcmp(catalog->strings + catalog->names[low].name_offset, name) != 0)
            return fail(&report, "export-not-found: exact name absent");
        index = catalog->names[low].index;
    } else return fail(&report, "invalid-argument: by_ordinal must be zero or one");
    const pm_export_entry *entry = &catalog->entries[index];
    if (entry->kind == 0) return fail(&report, "export-not-found: ordinal hole");
    pm_pe_export found = {0};
    found.kind = entry->kind; found.ordinal = catalog->base + index; found.rva = entry->rva;
    if (entry->kind == PM_PE_EXPORT_DIRECT) {
        if (entry->rva >= catalog->image_size || entry->rva >= image->mapping_size)
            return fail(&report, "exports-unavailable: direct address outside mapping");
        found.address = (const uint8_t *)image->mapping + entry->rva;
        found.executable = entry->executable; found.writable = entry->writable;
    } else if (entry->kind == PM_PE_EXPORT_FORWARDER) {
        found.forwarder = catalog->strings + entry->forwarder_offset;
    } else return fail(&report, "exports-unavailable: unknown export kind");
    *result = found;
    return 1;
}
