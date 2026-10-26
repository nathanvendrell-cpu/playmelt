/* Reuse private memory OS doubles; no external image and no PE entry executed. */
#define main memory_regression_not_invoked
#include "test_winapi_memory.c"
#undef main
#include "winapi_modules.h"

static unsigned char main_bytes[256],dll_bytes[256],undeclared_bytes[256];
static pm_pe_image image={.mapping=main_bytes,.mapping_size=sizeof main_bytes};
static pm_pe_image dll={.mapping=dll_bytes,.mapping_size=sizeof dll_bytes};
static pm_pe_image undeclared={.mapping=undeclared_bytes,.mapping_size=sizeof undeclared_bytes};
int pm_pe_find_export(const pm_pe_image *im,const char *name,uint32_t ordinal,int by_ordinal,
    pm_pe_export *out,char *error,size_t cap) {
    (void)im; (void)name; (void)ordinal; (void)by_ordinal; (void)out;
    if (error && cap) error[0]=0; return 0;
}
static pm_winapi_modules *modules(void) {
    pm_pe_modules registry; CHECK(pm_pe_modules_init(&registry,NULL,NULL));
    CHECK(pm_pe_modules_add(&registry,"sample.dll",&dll));
    CHECK(pm_pe_modules_add(&registry,"undeclared.dll",&undeclared));
    char error[128];
    pm_winapi_modules *ctx=pm_winapi_modules_create(&registry,&image,"fixture.exe",error,sizeof error);
    CHECK(ctx && !error[0]);
    CHECK(pm_winapi_modules_add_host(ctx,"kernel32.dll",pm_winapi_modules_resolve,NULL));
    return ctx;
}
static void refused(void *module,void *out,uint32_t cap,uint32_t error) {
    CHECK(pm_win_GetModuleFileNameA(module,out,cap)==0); CHECK(pm_win_GetLastError()==error);
}
static void *foreign_copy(void *out) {
    const char data[]="abc";
    pm_win_SetLastError(456);
    CHECK(!pm_winapi_memory_copy_bytes_owned(out,data,sizeof data));
    CHECK(pm_win_GetLastError()==456);
    refused(NULL,out,4,126); return NULL;
}
int main(void) {
    pm_winapi_modules *ctx=modules();
    pm_winapi_memory *mem=context(); size_t page=mem->page_size;
    unsigned char *out=allocate(mem,page*2),*aux=allocate(mem,page),*fault=allocate(mem,page);
    memset(out,0xa7,page*2);
    const char path[]="C:\\Declared Folder\\FiXtUrE.ExE";
    const char dllpath[]="D:\\Only_Metadata\\Sample.DLL";
    char source[512]; memcpy(source,path,sizeof path);
    const char *bad[]={NULL,"fixture.exe","C:fixture.exe","C:/fixture.exe","1:\\fixture.exe",
        "\\\\server\\fixture.exe","\\\\?\\C:\\fixture.exe","C:\\\\fixture.exe","C:\\.\\fixture.exe",
        "C:\\..\\fixture.exe","C:\\a.\\fixture.exe","C:\\a \\fixture.exe","C:\\a:b\\fixture.exe",
        "C:\\a?b\\fixture.exe","C:\\a*b\\fixture.exe","C:\\a|b\\fixture.exe","C:\\a<b\\fixture.exe",
        "C:\\a>b\\fixture.exe","C:\\a\"b\\fixture.exe","C:\\a/b\\fixture.exe","C:\\wrong.exe",
        "C:\\fixture.exe\\","C:\\fixture.exe ","C:\\caf\xc3\xa9\\fixture.exe","C:\\a\x1f\\fixture.exe"};
    pm_win_SetLastError(789);
    for (size_t i=0;i<sizeof bad/sizeof *bad;++i) {
        CHECK(!pm_winapi_modules_set_declared_path(ctx,&image,bad[i])); CHECK(pm_win_GetLastError()==789);
    }
    char too_long[513]; memset(too_long,'a',512); too_long[512]=0;
    CHECK(!pm_winapi_modules_set_declared_path(ctx,&image,too_long));
    pm_pe_image copy=image;
    CHECK(!pm_winapi_modules_set_declared_path(ctx,&copy,path));
    CHECK(!pm_winapi_modules_set_declared_path(ctx,NULL,path));
    CHECK(!pm_winapi_modules_set_declared_path(NULL,&image,path));
    CHECK(pm_winapi_modules_set_declared_path(ctx,&image,source));
    memset(source,'!',sizeof source); /* source lifetime/content no longer matters */
    CHECK(!pm_winapi_modules_set_declared_path(ctx,&image,"Z:\\fixture.exe"));
    dll.mapping=NULL; CHECK(!pm_winapi_modules_set_declared_path(ctx,&dll,dllpath)); dll.mapping=dll_bytes;
    CHECK(pm_winapi_modules_set_declared_path(ctx,&dll,dllpath));
    CHECK(pm_win_GetLastError()==789);
    refused(NULL,out,512,126); CHECK(out[0]==0xa7);
    CHECK(pm_winapi_modules_bind(ctx));
    refused(NULL,out,512,998); CHECK(out[0]==0xa7);
    CHECK(pm_winapi_memory_bind(mem));
    refused(NULL,NULL,0,122); refused(NULL,(void *)1,0,122);
    size_t length=strlen(path);
    const uint32_t capacities[]={0,1,(uint32_t)length,(uint32_t)length+1,UINT32_MAX};
    for (size_t i=0;i<sizeof capacities/sizeof *capacities;++i) {
        memset(out,0xa7,512); pm_win_SetLastError(345);
        uint32_t cap=capacities[i],result=pm_win_GetModuleFileNameA(NULL,out+1,cap);
        CHECK(out[0]==0xa7);
        if (!cap) { CHECK(!result && pm_win_GetLastError()==122); CHECK(out[1]==0xa7); }
        else if (cap<=length) {
            CHECK(result==cap && pm_win_GetLastError()==122);
            CHECK(!memcmp(out+1,path,cap-1) && out[cap]==0 && out[cap+1]==0xa7);
        } else {
            CHECK(result==length && pm_win_GetLastError()==345);
            CHECK(!memcmp(out+1,path,length+1) && out[length+2]==0xa7);
        }
    }
    unsigned char *end=out+2*page-(length+1);
    pm_win_SetLastError(346); CHECK(pm_win_GetModuleFileNameA(main_bytes,end,UINT32_MAX)==length);
    CHECK(!memcmp(end,path,length+1) && pm_win_GetLastError()==346);
    CHECK(pm_win_GetModuleFileNameA(dll_bytes,out,512)==strlen(dllpath)); CHECK(!strcmp((char *)out,dllpath));
    memset(out,0xa7,512);
    void *bad_modules[]={(void *)1,undeclared_bytes,pm_win_GetModuleHandleA("kernel32")};
    for (size_t i=0;i<3;++i) {
        refused(bad_modules[i],out,512,i==1?126:6); CHECK(out[0]==0xa7);
    }
    dll.mapping=NULL; refused(dll_bytes,out,512,6); CHECK(out[0]==0xa7); dll.mapping=dll_bytes;
    unsigned char unowned[512]; memset(unowned,0x6c,sizeof unowned);
    void *bad_outputs[]={NULL,(void *)1,(void *)(UINTPTR_MAX-3),out+2*page-length,unowned};
    for (size_t i=0;i<sizeof bad_outputs/sizeof *bad_outputs;++i) refused(NULL,bad_outputs[i],512,998);
    CHECK(unowned[0]==0x6c && unowned[511]==0x6c);
    unsigned char *cross=out+page-3; memset(cross,0xa7,64);
    CHECK(pm_win_VirtualProtect(out+page,1,PM_PAGE_READONLY,aux));
    refused(NULL,cross,512,998); for (size_t i=0;i<64;++i) CHECK(cross[i]==0xa7);
    CHECK(pm_win_VirtualProtect(out+page,1,PM_PAGE_READWRITE,aux));
    CHECK(pm_win_GetModuleFileNameA(NULL,cross,512)==length); CHECK(!strcmp((char *)cross,path));
    partial_protection_failure=1; CHECK(!pm_win_VirtualProtect(fault,1,PM_PAGE_READONLY,aux)); partial_protection_failure=0;
    CHECK(actual_permissions(fault)==VM_PROT_NONE); refused(NULL,fault,512,998);
    pthread_t thread; CHECK(pthread_create(&thread,NULL,foreign_copy,out)==0); CHECK(pthread_join(thread,NULL)==0);
    CHECK(pm_winapi_modules_unbind()); CHECK(!pm_winapi_modules_set_declared_path(ctx,&undeclared,"C:\\undeclared.dll"));
    CHECK(pm_winapi_modules_bind(ctx));
    CHECK(pm_win_GetModuleFileNameA(NULL,out,512)==length && !strcmp((char *)out,path));
    CHECK(pm_winapi_modules_unbind()); CHECK(pm_winapi_modules_destroy(&ctx));
    /* HOST helper: actual bounded source, zero/>512 refusal, overlap memmove. */
    char bytes[512]; memset(bytes,'x',sizeof bytes); memset(out,0xa7,512);
    pm_win_SetLastError(678);
    CHECK(!pm_winapi_memory_copy_bytes_owned(out,bytes,0));
    CHECK(!pm_winapi_memory_copy_bytes_owned(out,bytes,513));
    CHECK(!pm_winapi_memory_copy_bytes_owned(out,NULL,1)); CHECK(out[0]==0xa7);
    CHECK(pm_winapi_memory_copy_bytes_owned(out,bytes,512)); CHECK(!memcmp(out,bytes,512));
    memcpy(out,"abcdef",7); CHECK(pm_winapi_memory_copy_bytes_owned(out+1,out,6)); CHECK(!memcmp(out,"aabcdef",7));
    CHECK(pm_win_GetLastError()==678);
    CHECK(pm_winapi_memory_unbind()); CHECK(!pm_winapi_memory_copy_bytes_owned(out,bytes,1));
    CHECK(pm_winapi_memory_destroy(&mem));
    /* Max accepted 511-byte path; no filesystem operation is performed. */
    ctx=modules(); char longest[512]; memcpy(longest,"C:\\",3); memset(longest+3,'x',496);
    memcpy(longest+499,"\\fixture.exe",13);
    CHECK(strlen(longest)==511); CHECK(pm_winapi_modules_set_declared_path(ctx,&image,longest));
    mem=context(); out=allocate(mem,512); CHECK(pm_winapi_memory_bind(mem)); CHECK(pm_winapi_modules_bind(ctx));
    CHECK(pm_win_GetModuleFileNameA(NULL,out,512)==511 && !memcmp(out,longest,512));
    CHECK(pm_winapi_modules_unbind()); CHECK(pm_winapi_modules_destroy(&ctx));
    CHECK(pm_winapi_memory_unbind()); CHECK(pm_winapi_memory_destroy(&mem));
    CHECK(!mappings && !allocations && !wx_requests);
    printf("PASS: %u declared module path and bounded copy checks; no PE execution, real memory cleanup\n",atomic_load(&checks));
    return 0;
}
