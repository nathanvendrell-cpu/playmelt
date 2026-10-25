/* Reference: Microsoft PE Format, .idata and base relocations.
 * https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
 * No packed-struct casts: every untrusted integer is bounded and decoded LE.
 */
#include "pe_loader.h"

#include <limits.h>
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
#define PM_SCN_EXECUTE 0x20000000u
#define PM_SCN_READ 0x40000000u
#define PM_SCN_WRITE 0x80000000u

typedef struct {
    uint32_t rva, extent, raw_size, raw_offset, flags;
} pm_section;

typedef struct {
    const uint8_t *bytes;
    size_t size, page_size, mapping_size;
    uint64_t image_base;
    uint32_t image_size, header_size, entry, section_count;
    uint32_t dirs[16][2];
    pm_section sections[PM_MAX_SECTIONS];
    uint8_t *mapping, *permissions;
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
    if (attributes & 0x2000) return fail(p, "unsupported-dll: module initialization is not implemented");
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
    p->image_size = u32(opt + 56); p->header_size = u32(opt + 60);
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
        "unsupported-directory: exports", NULL, "unsupported-directory: resources",
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
            if (unsupported[i] != NULL) return fail(p, unsupported[i]);
            if (raw_at(p, rva, size) == NULL) return fail(p, "invalid-directory: metadata is not file-backed in one section");
        }
        p->dirs[i][0] = rva; p->dirs[i][1] = size;
    }
    const pm_section *entry_section = section_for(p, p->entry, 1);
    if (p->entry == 0 || entry_section == NULL || !(entry_section->flags & PM_SCN_EXECUTE) || raw_at(p, p->entry, 1) == NULL)
        return fail(p, "invalid-entry: entry point must be file-backed in an executable section");
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
            if (value == 0) { put64(p->mapping + (uint32_t)iat64, 0); break; }
            if (symbol_count >= PM_MAX_IMPORTS) return fail(p, "import-limit: more than 1024 named symbols");
            if (value & (UINT64_C(1) << 63)) return fail(p, "unsupported-import: ordinal resolution is not implemented");
            if (value >= UINT64_C(0x80000000) || raw_at(p, (uint32_t)value, 2) == NULL)
                return fail(p, "invalid-imports: hint/name RVA is invalid");
            const char *function = ascii_at(p, (uint32_t)value + 2u, 256);
            if (function == NULL) return fail(p, "invalid-imports: symbol is not bounded printable ASCII");
            ++symbol_count;
            uintptr_t address = 0;
            if (resolver == NULL || resolver(context, dll, function, 0, 0, &address) != 1 || address == 0)
                return fail(p, "unresolved-import: resolver refused a named dependency");
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

int pm_pe_load(const uint8_t *bytes, size_t size, pm_import_resolver resolver,
               void *context, pm_pe_image *image, char *error, size_t error_cap) {
    pm_loader p = {0};
    p.bytes = bytes; p.size = size; p.error = error; p.error_cap = error_cap;
    if (error != NULL && error_cap) error[0] = '\0';
    if (image == NULL) return fail(&p, "invalid-argument: output image is null");
    if (image->mapping != NULL || image->mapping_size != 0 || image->entrypoint_rva != 0)
        return fail(&p, "invalid-argument: unload the previous image before reuse");
    int ok = parse_headers(&p);
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
        ok = relocate(&p) && bind_imports(&p, resolver, context) && protect_image(&p);
    }
    free(p.permissions);
    if (!ok) {
        if (p.mapping != NULL && munmap(p.mapping, p.mapping_size) != 0) {
            image->mapping = p.mapping;
            image->mapping_size = p.mapping_size;
            image->entrypoint_rva = 0;
            return fail(&p, "cleanup-failed: partial mapping retained; retry pm_pe_unload");
        }
        return 0;
    }
    image->mapping = p.mapping;
    image->mapping_size = p.mapping_size;
    image->entrypoint_rva = p.entry;
    return 1;
}

int pm_pe_unload(pm_pe_image *image) {
    if (image == NULL) return 1;
    if ((image->mapping == NULL) != (image->mapping_size == 0)) return 0;
    if (image->mapping != NULL && munmap(image->mapping, image->mapping_size) != 0) return 0;
    *image = (pm_pe_image){0};
    return 1;
}
