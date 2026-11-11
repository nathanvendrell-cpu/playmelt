// Set only a missing per-prefix Wine macdrv RetinaMode. Existing preference wins.
#include <windows.h>
#include <cstdio>
#include <cstring>
int main(int argc,char **argv) {
    if(argc!=2 || std::strcmp(argv[1],"--ensure-default")) return 64;
    HKEY key=nullptr; DWORD disposition=0;
    LONG e=RegCreateKeyExW(HKEY_CURRENT_USER,L"Software\\Wine\\Mac Driver",0,nullptr,0,KEY_QUERY_VALUE|KEY_SET_VALUE,nullptr,&key,&disposition);
    if(e!=ERROR_SUCCESS){std::printf("{\"ok\":false,\"error\":%ld}\n",e);return 1;}
    DWORD type=0,size=0;e=RegQueryValueExW(key,L"RetinaMode",nullptr,&type,nullptr,&size);
    if(e==ERROR_SUCCESS){RegCloseKey(key);std::puts("{\"ok\":true,\"status\":\"existing_preserved\"}");return 0;}
    if(e!=ERROR_FILE_NOT_FOUND){RegCloseKey(key);std::printf("{\"ok\":false,\"error\":%ld}\n",e);return 1;}
    const wchar_t value[]=L"Y";
    e=RegSetValueExW(key,L"RetinaMode",0,REG_SZ,reinterpret_cast<const BYTE*>(value),sizeof(value));
    if(e==ERROR_SUCCESS)e=RegFlushKey(key);
    wchar_t actual[8]{};DWORD actualType=0,actualSize=sizeof(actual);
    const LONG r=RegQueryValueExW(key,L"RetinaMode",nullptr,&actualType,reinterpret_cast<BYTE*>(actual),&actualSize);
    RegCloseKey(key);
    const bool ok=e==ERROR_SUCCESS&&r==ERROR_SUCCESS&&actualType==REG_SZ&&actualSize==sizeof(value)&&actual[0]==L'Y'&&actual[1]==0;
    std::printf("{\"ok\":%s,\"status\":\"%s\"}\n",ok?"true":"false",ok?"created":"unverified");return ok?0:1;
}
