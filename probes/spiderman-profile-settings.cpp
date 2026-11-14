// Import only selected first-run preferences, preserving every existing value.
#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <string>
#include <vector>
#include <dxgi1_2.h>
static int display_target() {
    IDXGIFactory1 *factory=nullptr;
    if(FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1),reinterpret_cast<void**>(&factory))))return 1;
    IDXGIAdapter1 *adapter=nullptr;
    if(FAILED(factory->EnumAdapters1(0,&adapter))){factory->Release();return 1;}
    unsigned matches=0,index=0;RECT rect{};DWORD hz=0;
    for(unsigned i=0;i<64;++i){
        IDXGIOutput *output=nullptr;if(FAILED(adapter->EnumOutputs(i,&output)))break;
        DXGI_OUTPUT_DESC desc{};MONITORINFO info{};info.cbSize=sizeof(info);
        if(SUCCEEDED(output->GetDesc(&desc)) && desc.AttachedToDesktop && GetMonitorInfoW(desc.Monitor,&info) && (info.dwFlags&MONITORINFOF_PRIMARY)){
            DEVMODEW mode{};mode.dmSize=sizeof(mode);
            if(EnumDisplaySettingsExW(desc.DeviceName,ENUM_CURRENT_SETTINGS,&mode,0)){++matches;index=i;rect=desc.DesktopCoordinates;hz=mode.dmDisplayFrequency;}
        }
        output->Release();
    }
    adapter->Release();factory->Release();
    if(matches!=1 || hz<=1)return 1;
    std::printf("{\"ok\":true,\"monitorIndex\":%u,\"x\":%ld,\"y\":%ld,\"width\":%ld,\"height\":%ld,\"refreshRate\":%lu}\n",index,rect.left,rect.top,rect.right-rect.left,rect.bottom-rect.top,static_cast<unsigned long>(hz));return 0;
}
struct Item { const char *name; const char *kind; const char *value; };
static bool allowed(const char *n) {
    const char *names[]={"Fullscreen","ExclusiveFullscreen","FullscreenWidth","FullscreenHeight","WindowLeft","WindowTop","WindowWidth","WindowHeight","UserWindowWidth","UserWindowHeight","DynamicResolutionTargetFPS","UpscaleMethod","UpscaleQuality","RefreshRate"};
    for(const char *x:names) if(!std::strcmp(n,x))return true;
    return false;
}
static bool allowed_root(const char *n) {
    const char *names[]={"FirstRun","englishVO","TextLanguage","ShowLauncher"};
    for(const char *x:names) if(!std::strcmp(n,x))return true;
    return false;
}
int main(int argc,char **argv){
    if(argc==2 && !std::strcmp(argv[1],"--display"))return display_target();
    if(argc<4 || std::strcmp(argv[1],"--import") || (argc-2)%3 || argc>68)return 64;
    std::vector<Item> items;
    for(int i=2;i<argc;i+=3){
        if(!std::strcmp(argv[i],"dword") || !std::strcmp(argv[i],"root")){
            if((!std::strcmp(argv[i],"dword") ? !allowed(argv[i+1]) : !allowed_root(argv[i+1])) || !*argv[i+2])return 64;
            char *end=nullptr; const unsigned long v=std::strtoul(argv[i+2],&end,10);
            if(*end || v>0xffffffffUL)return 64;
        }else if(!std::strcmp(argv[i],"mac")){
            if((std::strcmp(argv[i+1],"RetinaMode") && std::strcmp(argv[i+1],"CaptureDisplaysForFullscreen")) ||
               (std::strcmp(argv[i+2],"Y") && std::strcmp(argv[i+2],"N")))return 64;
        }else return 64;
        for(const Item &x:items)if(!std::strcmp(x.name,argv[i+1]))return 64;
        items.push_back({argv[i+1],argv[i],argv[i+2]});
    }
    unsigned created=0,preserved=0;
    for(const Item &x:items){
        const bool mac=!std::strcmp(x.kind,"mac");
        const bool root=!std::strcmp(x.kind,"root");
        const wchar_t *path=mac?L"Software\\Wine\\Mac Driver":root?L"Software\\Insomniac Games\\Marvel's Spider-Man 2":L"Software\\Insomniac Games\\Marvel's Spider-Man 2\\Graphics";
        wchar_t name[128]{};if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,x.name,-1,name,128))return 1;
        HKEY key=nullptr;DWORD disposition=0;LONG e=RegCreateKeyExW(HKEY_CURRENT_USER,path,0,nullptr,0,KEY_QUERY_VALUE|KEY_SET_VALUE,nullptr,&key,&disposition);
        if(e!=ERROR_SUCCESS){std::printf("{\"ok\":false,\"error\":%ld}\n",e);return 1;}
        DWORD type=0,size=0;e=RegQueryValueExW(key,name,nullptr,&type,nullptr,&size);
        if(e==ERROR_SUCCESS){RegCloseKey(key);++preserved;continue;}
        if(e!=ERROR_FILE_NOT_FOUND){RegCloseKey(key);std::printf("{\"ok\":false,\"error\":%ld}\n",e);return 1;}
        DWORD number=0;wchar_t letter[2]{};const BYTE *data=nullptr;DWORD bytes=0;
        if(mac){letter[0]=wchar_t(x.value[0]);data=reinterpret_cast<const BYTE*>(letter);bytes=sizeof(letter);type=REG_SZ;}
        else{number=static_cast<DWORD>(std::strtoul(x.value,nullptr,10));data=reinterpret_cast<const BYTE*>(&number);bytes=sizeof(number);type=REG_DWORD;}
        e=RegSetValueExW(key,name,0,type,data,bytes);if(e==ERROR_SUCCESS)e=RegFlushKey(key);
        BYTE check[16]{};DWORD checktype=0,checksize=sizeof(check);LONG r=RegQueryValueExW(key,name,nullptr,&checktype,check,&checksize);
        RegCloseKey(key);
        if(e!=ERROR_SUCCESS || r!=ERROR_SUCCESS || checktype!=type || checksize!=bytes || std::memcmp(check,data,bytes)){
            std::printf("{\"ok\":false,\"error\":%ld}\n",e);return 1;
        }
        ++created;
    }
    std::printf("{\"ok\":true,\"created\":%u,\"preserved\":%u}\n",created,preserved);return 0;
}
