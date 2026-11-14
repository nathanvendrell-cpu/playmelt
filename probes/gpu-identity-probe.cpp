// Read-only GPU identity and D3D12 capability diagnostic. No registry writes.
#define WIN32_LEAN_AND_MEAN
#define INITGUID
#include <windows.h>
#include <setupapi.h>
#include <devguid.h>
#include <dxgi1_4.h>
#include <d3d12.h>
#include <cstdio>
#include <string>
#include <vector>

static std::string utf8(const wchar_t *s) {
    if (!s) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, s, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 0) return "";
    std::string out((size_t)n, '\0');
    if (!WideCharToMultiByte(CP_UTF8, 0, s, -1, &out[0], n, nullptr, nullptr)) return "";
    out.resize((size_t)n - 1); return out;
}
static void jstr(const std::string &s) {
    putchar('"'); for (unsigned char c : s) {
        switch(c) { case '"': fputs("\\\"",stdout); break; case '\\': fputs("\\\\",stdout); break;
        case '\b': fputs("\\b",stdout); break; case '\f': fputs("\\f",stdout); break;
        case '\n': fputs("\\n",stdout); break; case '\r': fputs("\\r",stdout); break;
        case '\t': fputs("\\t",stdout); break; default: if(c<32) printf("\\u%04x",c); else putchar(c); }
    } putchar('"');
}
static void hr(HRESULT h) { printf("\"0x%08lX\"",(unsigned long)(DWORD)h); }
static void property(HDEVINFO set, SP_DEVINFO_DATA *dev, DWORD prop) {
    DWORD type=0, bytes=0; SetLastError(0);
    if (!SetupDiGetDeviceRegistryPropertyW(set,dev,prop,&type,nullptr,0,&bytes) && GetLastError()!=ERROR_INSUFFICIENT_BUFFER) {
        printf("{\"win32_error\":%lu}",(unsigned long)GetLastError()); return;
    }
    if (!bytes || bytes>1024*1024 || bytes%sizeof(wchar_t)) { fputs("{\"error\":\"invalid_length\"}",stdout); return; }
    std::vector<wchar_t> b(bytes/sizeof(wchar_t)+2,0);
    if(!SetupDiGetDeviceRegistryPropertyW(set,dev,prop,&type,(PBYTE)b.data(),bytes,nullptr)) { printf("{\"win32_error\":%lu}",(unsigned long)GetLastError()); return; }
    printf("{\"reg_type\":%lu,\"values\":[",(unsigned long)type);
    if(type==REG_SZ || type==REG_MULTI_SZ || type==REG_EXPAND_SZ) {
        bool first=true; size_t i=0, limit=bytes/sizeof(wchar_t);
        while(i<limit && b[i]) { size_t end=i; while(end<limit && b[end]) ++end; if(!first) putchar(','); first=false; std::wstring item(&b[i],end-i); jstr(utf8(item.c_str())); i=end+1; if(type!=REG_MULTI_SZ) break; }
    }
    fputs("]}",stdout);
}
static void driver_property(HKEY key,const wchar_t *name) {
    DWORD type=0, bytes=0; LSTATUS rc=RegQueryValueExW(key,name,nullptr,&type,nullptr,&bytes);
    if(rc!=ERROR_SUCCESS){ printf("{\"win32_error\":%ld}",(long)rc); return; }
    if(!bytes || bytes>1024*1024 || bytes%sizeof(wchar_t)){ fputs("{\"error\":\"invalid_length\"}",stdout); return; }
    std::vector<wchar_t> b(bytes/sizeof(wchar_t)+2,0);
    rc=RegQueryValueExW(key,name,nullptr,&type,(LPBYTE)b.data(),&bytes);
    if(rc!=ERROR_SUCCESS){printf("{\"win32_error\":%ld}",(long)rc);return;}
    printf("{\"reg_type\":%lu,\"value\":",(unsigned long)type);
    if(type==REG_SZ || type==REG_EXPAND_SZ) jstr(utf8(b.data())); else fputs("null",stdout); putchar('}');
}
int main(int argc,char **argv) {
    if(argc!=2 || !argv[1][0] || strlen(argv[1])>128){ fputs("usage: gpu-identity-probe NONCE\n",stderr); return 2; }
    fputs("{\"schema\":1,\"nonce\":",stdout); jstr(argv[1]); fputs(",\"dxgi\":{\"api\":\"CreateDXGIFactory1/EnumAdapters1/GetDesc1/CheckInterfaceSupport/D3D12CreateDevice\",\"factory_hresult\":",stdout);
    IDXGIFactory1 *factory=nullptr; HRESULT f=CreateDXGIFactory1(__uuidof(IDXGIFactory1),(void**)&factory); hr(f); fputs(",\"adapters\":[",stdout);
    if(SUCCEEDED(f) && factory) {
        bool first=true; for(UINT i=0;i<64;i++) {
            IDXGIAdapter1 *a=nullptr; HRESULT e=factory->EnumAdapters1(i,&a);
            if(e==DXGI_ERROR_NOT_FOUND) break;
            if(!first) putchar(',');
            first=false; printf("{\"index\":%u,\"enum_hresult\":",i); hr(e);
            if(FAILED(e)||!a){putchar('}');break;}
            DXGI_ADAPTER_DESC1 d={}; HRESULT h=a->GetDesc1(&d); fputs(",\"desc_hresult\":",stdout);hr(h);
            if(SUCCEEDED(h)){fputs(",\"description\":",stdout);jstr(utf8(d.Description));printf(",\"vendor_id\":%u,\"device_id\":%u,\"subsystem_id\":%u,\"revision\":%u,\"flags\":%u,\"luid_high\":%ld,\"luid_low\":%lu",d.VendorId,d.DeviceId,d.SubSysId,d.Revision,d.Flags,(long)d.AdapterLuid.HighPart,(unsigned long)d.AdapterLuid.LowPart);}
            fputs(",\"outputs\":[",stdout); bool firstOutput=true;
            for(UINT oi=0;oi<64;oi++) { IDXGIOutput *output=nullptr; HRESULT oe=a->EnumOutputs(oi,&output); if(oe==DXGI_ERROR_NOT_FOUND) break;
                if(!firstOutput) putchar(',');
                firstOutput=false; printf("{\"index\":%u,\"enum_hresult\":",oi); hr(oe);
                if(SUCCEEDED(oe) && output) { DXGI_OUTPUT_DESC od={}; HRESULT dh=output->GetDesc(&od); fputs(",\"desc_hresult\":",stdout);hr(dh);
                    if(SUCCEEDED(dh)) {fputs(",\"device_name\":",stdout);jstr(utf8(od.DeviceName));printf(",\"attached_to_desktop\":%s",od.AttachedToDesktop?"true":"false");} output->Release(); }
                putchar('}'); if(FAILED(oe)) break;
            } fputs("]",stdout);
            LARGE_INTEGER version={}; HRESULT v=a->CheckInterfaceSupport(__uuidof(IDXGIDevice),&version);fputs(",\"check_interface\":{\"iid\":\"IDXGIDevice\",\"hresult\":",stdout);hr(v);if(SUCCEEDED(v))printf(",\"driver_version_high\":%lu,\"driver_version_low\":%lu",(unsigned long)version.HighPart,(unsigned long)version.LowPart);putchar('}');
            fputs(",\"d3d12_create_device\":[",stdout); const D3D_FEATURE_LEVEL levels[]={D3D_FEATURE_LEVEL_12_1,D3D_FEATURE_LEVEL_12_0,D3D_FEATURE_LEVEL_11_1,D3D_FEATURE_LEVEL_11_0}; const char *names[]={"12_1","12_0","11_1","11_0"};
            for(int k=0;k<4;k++){if(k)putchar(',');ID3D12Device *device=nullptr;HRESULT z=D3D12CreateDevice(a,levels[k],__uuidof(ID3D12Device),(void**)&device);fputs("{\"minimum_feature_level\":",stdout);jstr(names[k]);fputs(",\"hresult\":",stdout);hr(z);
                if(SUCCEEDED(z) && device) {
                    LUID dl=device->GetAdapterLuid(); printf(",\"device_adapter_luid_high\":%ld,\"device_adapter_luid_low\":%lu",(long)dl.HighPart,(unsigned long)dl.LowPart);
                    D3D12_FEATURE_DATA_D3D12_OPTIONS5 opts={}; HRESULT oh=device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5,&opts,sizeof(opts));
                    fputs(",\"options5\":{\"hresult\":",stdout);hr(oh);if(SUCCEEDED(oh))printf(",\"raytracing_tier\":%u",(unsigned)opts.RaytracingTier);putchar('}');
                    D3D12_FEATURE_DATA_SHADER_MODEL sm={}; sm.HighestShaderModel=D3D_SHADER_MODEL_6_6; HRESULT sh=device->CheckFeatureSupport(D3D12_FEATURE_SHADER_MODEL,&sm,sizeof(sm));
                    fputs(",\"shader_model\":{\"requested_max\":\"0x66\",\"hresult\":",stdout);hr(sh);if(SUCCEEDED(sh))printf(",\"highest_returned\":\"0x%X\"",(unsigned)sm.HighestShaderModel);putchar('}');
                }
                putchar('}');if(device)device->Release();}
            fputs("]}",stdout);a->Release();
        } factory->Release();
    }
    fputs("]},\"display_devices\":{\"api\":\"EnumDisplayDevicesW\",\"devices\":[",stdout);
    DWORD displayStopError=0; bool displayStopped=false;
    for(DWORD i=0;i<64;i++) { DISPLAY_DEVICEW dd={};dd.cb=sizeof(dd); SetLastError(0); if(!EnumDisplayDevicesW(nullptr,i,&dd,0)) {displayStopError=GetLastError();displayStopped=true;break;}
        if(i)putchar(',');
        printf("{\"index\":%lu,\"device_name\":",(unsigned long)i);jstr(utf8(dd.DeviceName));fputs(",\"device_id\":",stdout);jstr(utf8(dd.DeviceID));fputs(",\"device_key\":",stdout);jstr(utf8(dd.DeviceKey));printf(",\"state_flags\":%lu,\"attached_to_desktop\":%s,\"primary_device\":%s}",(unsigned long)dd.StateFlags,(dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)?"true":"false",(dd.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE)?"true":"false");
    }
    printf("],\"ended_before_limit\":%s,\"last_error_at_end\":%lu},",displayStopped?"true":"false",(unsigned long)displayStopError);
    fputs("\"setupapi\":{\"api\":\"SetupDiGetClassDevsW/EnumDeviceInfo/GetDeviceRegistryPropertyW/RegQueryValueExW\",\"devices\":[",stdout);
    HDEVINFO set=SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY,nullptr,nullptr,DIGCF_PRESENT); DWORD setupError=0;
    if(set==INVALID_HANDLE_VALUE) setupError=GetLastError(); else {
        bool first=true; for(DWORD i=0;i<256;i++) {SP_DEVINFO_DATA d={};d.cbSize=sizeof(d); if(!SetupDiEnumDeviceInfo(set,i,&d)){DWORD err=GetLastError();if(err!=ERROR_NO_MORE_ITEMS)setupError=err;break;}
            if(!first) putchar(',');
            first=false; printf("{\"index\":%lu,\"device_desc\":",(unsigned long)i);property(set,&d,SPDRP_DEVICEDESC);fputs(",\"hardware_ids\":",stdout);property(set,&d,SPDRP_HARDWAREID);
            fputs(",\"driver_key\":",stdout);HKEY key=SetupDiOpenDevRegKey(set,&d,DICS_FLAG_GLOBAL,0,DIREG_DRV,KEY_READ);if(key==INVALID_HANDLE_VALUE)printf("{\"win32_error\":%lu}",(unsigned long)GetLastError());else{fputs("{\"driver_desc\":",stdout);driver_property(key,L"DriverDesc");fputs(",\"matching_device_id\":",stdout);driver_property(key,L"MatchingDeviceId");putchar('}');RegCloseKey(key);}putchar('}');
        } SetupDiDestroyDeviceInfoList(set);
    }
    fputs("],\"enumeration_win32_error\":",stdout);printf("%lu}}\n",(unsigned long)setupError);return 0;
}
