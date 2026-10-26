/* Link only winapi_combined.c: provider doubles, no actual Windows call/PE. */
#include "winapi_combined.h"
#include <stdio.h>
#include <stdlib.h>

static unsigned checks,calls;
static int replies[4];
static uintptr_t addresses[4];
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x); abort(); } } while (0)
static int provider(unsigned i,void *ctx,const char *dll,const char *name,
    uint16_t ordinal,int by_ordinal,uintptr_t *address) {
    CHECK(!ctx && dll && name && !ordinal && !by_ordinal && address);
    ++calls; *address=addresses[i]; return replies[i];
}
#define MOCK(n,i) int n(void *c,const char *d,const char *s,uint16_t o,int b,uintptr_t *a) { return provider(i,c,d,s,o,b,a); }
MOCK(pm_winapi_resolve,0)
MOCK(pm_winapi_modules_resolve,1)
MOCK(pm_winapi_memory_resolve,2)
MOCK(pm_winapi_events_resolve,3)
#undef MOCK
int main(void) {
    for (unsigned mask=0;mask<16;++mask) {
        calls=0;
        for (unsigned i=0;i<4;++i) { replies[i]=(mask>>i)&1; addresses[i]=replies[i]?42:0; }
        uintptr_t out=999;
        CHECK(pm_winapi_combined_resolve(NULL,"kernel32.dll","GetLastError",0,0,&out)==(mask!=0));
        CHECK(out==(mask?42:0) && calls==4);
    }
    for (unsigned a=0;a<4;++a) for (unsigned b=a+1;b<4;++b) {
        for (unsigned i=0;i<4;++i) { replies[i]=0; addresses[i]=0; }
        replies[a]=replies[b]=1; addresses[a]=42; addresses[b]=43;
        uintptr_t out=999;
        CHECK(!pm_winapi_combined_resolve(NULL,"kernelbase.dll","VirtualProtect",0,0,&out));
        CHECK(!out);
    }
    for (unsigned i=0;i<4;++i) for (unsigned malformed=0;malformed<4;++malformed) {
        for (unsigned j=0;j<4;++j) { replies[j]=1; addresses[j]=42; }
        replies[i]=malformed==0?0:malformed==1?1:malformed==2?-1:2;
        addresses[i]=malformed==1?0:42;
        uintptr_t out=999;
        CHECK(!pm_winapi_combined_resolve(NULL,"kernel32.dll","GetLastError",0,0,&out));
        CHECK(!out);
    }
    calls=0; uintptr_t out=999;
    CHECK(!pm_winapi_combined_resolve(NULL,"kernel32.dll","NtQueryVirtualMemory",0,0,&out) && !out);
    CHECK(!pm_winapi_combined_resolve(NULL,"ntdll.dll","VirtualProtect",0,0,&out) && !out);
    CHECK(!pm_winapi_combined_resolve(NULL,"unregistered.dll","GetLastError",0,0,&out) && !out);
    CHECK(!pm_winapi_combined_resolve(NULL,"kernel32.dll","GetLastError",1,0,&out) && !out);
    CHECK(!pm_winapi_combined_resolve(NULL,"kernel32.dll","GetLastError",0,2,&out) && !out);
    CHECK(!pm_winapi_combined_resolve(NULL,"kernel32.dll","FutureUnknownAPI",0,0,&out) && !out);
    CHECK(!calls);
    printf("PASS: %u combined resolver collision checks; providers mocked, no PE executed\n",checks);
    return 0;
}
