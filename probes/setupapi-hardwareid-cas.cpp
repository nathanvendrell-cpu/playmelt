// Review-only targeted registry CAS helper for a private test prefix.
// Does not modify game files, drivers, PCI enumeration keys or capabilities.
// A host-side durable undo journal and prefix validation are mandatory BEFORE
// invoking --apply; do not invoke this helper directly on a shared prefix.
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static const wchar_t KEY[] = L"SYSTEM\\CurrentControlSet\\Enum\\PCI\\VEN_106B&DEV_03F1&SUBSYS_00000000&REV_00\\00000000";
static const wchar_t NAME[] = L"HardwareID";
static const wchar_t APPLE[] = L"PCI\\VEN_106B&DEV_03F1&SUBSYS_00000000&REV_00\0";
static const wchar_t COMPAT[] = L"PCI\\VEN_1002&DEV_66AF&SUBSYS_00000000&REV_00\0";
static std::string hex(const std::vector<BYTE>& data) {
    static const char h[]="0123456789abcdef"; std::string s; s.reserve(data.size()*2);
    for(BYTE b:data){s+=h[b>>4];s+=h[b&15];} return s;
}
static bool readValue(HKEY key,DWORD& type,std::vector<BYTE>& data) {
    DWORD n=0; LONG e=RegQueryValueExW(key,NAME,nullptr,&type,nullptr,&n);
    if(e!=ERROR_SUCCESS || n>8192) return false;
    data.resize(n); DWORD size=n;
    return RegQueryValueExW(key,NAME,nullptr,&type,data.data(),&size)==ERROR_SUCCESS && size==n;
}
static std::vector<BYTE> bytes(const wchar_t* value,size_t n) {
    const BYTE* p=reinterpret_cast<const BYTE*>(value); return std::vector<BYTE>(p,p+n);
}
int main(int argc,char **argv) {
    if(argc!=2 || (std::strcmp(argv[1],"--read") && std::strcmp(argv[1],"--apply") && std::strcmp(argv[1],"--undo"))) return 64;
    const bool readOnly=!std::strcmp(argv[1],"--read"), apply=!std::strcmp(argv[1],"--apply");
    HKEY key=nullptr; LONG e=RegOpenKeyExW(HKEY_LOCAL_MACHINE,KEY,0,KEY_QUERY_VALUE|(readOnly?0:KEY_SET_VALUE),&key);
    if(e!=ERROR_SUCCESS){std::printf("{\"ok\":false,\"stage\":\"open\",\"error\":%ld}\n",e);return 1;}
    DWORD type=0; std::vector<BYTE> current;
    if(!readValue(key,type,current)){RegCloseKey(key);std::puts("{\"ok\":false,\"stage\":\"read\"}");return 1;}
    if(readOnly){std::printf("{\"ok\":true,\"type\":%lu,\"hex\":\"%s\"}\n",static_cast<unsigned long>(type),hex(current).c_str());RegCloseKey(key);return 0;}
    const auto original=bytes(APPLE,sizeof(APPLE)), target=bytes(COMPAT,sizeof(COMPAT));
    if(type!=REG_MULTI_SZ || current!=(apply?original:target)){
        std::printf("{\"ok\":false,\"stage\":\"compare\",\"type\":%lu,\"hex\":\"%s\"}\n",static_cast<unsigned long>(type),hex(current).c_str());RegCloseKey(key);return 2;
    }
    const auto& next=apply?target:original;
    e=RegSetValueExW(key,NAME,0,REG_MULTI_SZ,next.data(),static_cast<DWORD>(next.size()));
    if(e==ERROR_SUCCESS) e=RegFlushKey(key);
    DWORD actualType=0; std::vector<BYTE> actual; const bool verified=readValue(key,actualType,actual);
    RegCloseKey(key);
    const bool ok=e==ERROR_SUCCESS && verified && actualType==REG_MULTI_SZ && actual==next;
    std::printf("{\"ok\":%s,\"stage\":\"%s\",\"error\":%ld,\"type\":%lu,\"hex\":\"%s\"}\n",ok?"true":"false",apply?"apply":"undo",e,static_cast<unsigned long>(actualType),hex(actual).c_str());
    return ok?0:1;
}
