// Read-only display-identity probe. No window inspection, registry writes or GPU creation.
#include <windows.h>
#include <setupapi.h>
#include <devguid.h>
#include <devpropdef.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static std::string json(const wchar_t *s) {
    if (!s || !*s) return "";
    int n=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,s,-1,nullptr,0,nullptr,nullptr);
    if (n<=0) return "";
    std::string value(static_cast<size_t>(n),'\0'), out;
    if (!WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,s,-1,&value[0],n,nullptr,nullptr)) return "";
    value.pop_back();
    for (unsigned char c:value) {
        if(c=='\\'||c=='"'){out+='\\';out+=char(c);}
        else if(c<32){char b[7];std::snprintf(b,sizeof(b),"\\u%04x",c);out+=b;}
        else out+=char(c);
    }
    return out;
}
static std::string prop(HDEVINFO info, SP_DEVINFO_DATA *dev, DWORD property) {
    wchar_t buffer[4096]{}; DWORD type=0,needed=0;
    if (!SetupDiGetDeviceRegistryPropertyW(info,dev,property,&type,reinterpret_cast<PBYTE>(buffer),sizeof(buffer)-sizeof(wchar_t),&needed)) return "";
    if(type!=REG_SZ && type!=REG_MULTI_SZ && type!=REG_EXPAND_SZ) return "";
    buffer[4095]=0; return json(buffer);
}
static bool nonceValid(const char *s) {
    if(std::strlen(s)!=36) return false;
    for(int i=0;i<36;i++){char c=s[i];if(i==8||i==13||i==18||i==23){if(c!='-')return false;}else if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')||(c>='A'&&c<='F')))return false;}
    return true;
}
int main(int argc,char **argv) {
    if(argc!=3 || std::strcmp(argv[1],"--nonce") || !nonceValid(argv[2])) return 64;
    std::printf("{\"schema\":1,\"kind\":\"playmelt-setupapi-display-probe\",\"nonce\":\"%s\",\"displayDevices\":[",argv[2]);
    unsigned count=0;
    for(DWORD i=0;i<64;i++) {
        DISPLAY_DEVICEW d{};d.cb=sizeof(d);
        if(!EnumDisplayDevicesW(nullptr,i,&d,0)) break;
        std::printf("%s{\"deviceName\":\"%s\",\"deviceString\":\"%s\",\"deviceID\":\"%s\",\"deviceKey\":\"%s\",\"stateFlags\":%lu}",
            count?",":"",json(d.DeviceName).c_str(),json(d.DeviceString).c_str(),json(d.DeviceID).c_str(),json(d.DeviceKey).c_str(),static_cast<unsigned long>(d.StateFlags));
        ++count;
    }
    std::printf("],\"setupDevices\":[");
    HDEVINFO info=SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY,nullptr,nullptr,DIGCF_PRESENT);
    const bool setupOK=info!=INVALID_HANDLE_VALUE; DWORD lastError=setupOK?ERROR_SUCCESS:GetLastError(); unsigned found=0;
    if(setupOK){
        for(DWORD i=0;i<64;i++){
            SP_DEVINFO_DATA data{};data.cbSize=sizeof(data);
            if(!SetupDiEnumDeviceInfo(info,i,&data)){lastError=GetLastError();break;}
            wchar_t instance[4096]{}; DWORD need=0;
            if(!SetupDiGetDeviceInstanceIdW(info,&data,instance,4096,&need)) instance[0]=0;
            std::printf("%s{\"instanceId\":\"%s\",\"deviceDesc\":\"%s\",\"hardwareId\":\"%s\",\"driver\":\"%s\",\"friendlyName\":\"%s\"}",
                found?",":"",json(instance).c_str(),prop(info,&data,SPDRP_DEVICEDESC).c_str(),prop(info,&data,SPDRP_HARDWAREID).c_str(),prop(info,&data,SPDRP_DRIVER).c_str(),prop(info,&data,SPDRP_FRIENDLYNAME).c_str());
            found++;
        }
        SetupDiDestroyDeviceInfoList(info);
    }
    bool complete=setupOK && lastError==ERROR_NO_MORE_ITEMS;
    std::printf("],\"setupComplete\":%s,\"setupError\":%lu,\"displayCount\":%u,\"setupCount\":%u,\"interfaces\":[",complete?"true":"false",static_cast<unsigned long>(lastError),count,found);
    const GUID interfaceID={0x5b45201d,0xf2f2,0x4f3b,{0x85,0xbb,0x30,0xff,0x1f,0x95,0x35,0x99}};
    const DEVPROPKEY friendlyKey={{0x026e516e,0xb814,0x414b,{0x83,0xcd,0x85,0x6d,0x6f,0xef,0x48,0x22}},2};
    using GetInterfaceProperty = BOOL (WINAPI *)(HDEVINFO,PSP_DEVICE_INTERFACE_DATA,const DEVPROPKEY*,DEVPROPTYPE*,PBYTE,DWORD,PDWORD,DWORD);
    FARPROC rawProperty=GetProcAddress(GetModuleHandleW(L"setupapi.dll"),"SetupDiGetDeviceInterfacePropertyW");
    GetInterfaceProperty getProperty=nullptr;
    static_assert(sizeof(getProperty)==sizeof(rawProperty),"Windows function pointer size mismatch");
    std::memcpy(&getProperty,&rawProperty,sizeof(getProperty));
    HDEVINFO interfaces=SetupDiGetClassDevsW(&interfaceID,nullptr,nullptr,DIGCF_PRESENT|DIGCF_DEVICEINTERFACE);
    bool interfacesOK=interfaces!=INVALID_HANDLE_VALUE; DWORD interfaceError=interfacesOK?ERROR_SUCCESS:GetLastError(); unsigned interfaceCount=0;
    if(interfacesOK) {
        for(DWORD i=0;i<64;i++) {
            SP_DEVICE_INTERFACE_DATA interfaceData{};interfaceData.cbSize=sizeof(interfaceData);
            if(!SetupDiEnumDeviceInterfaces(interfaces,nullptr,&interfaceID,i,&interfaceData)){interfaceError=GetLastError();break;}
            DWORD size=0;SetupDiGetDeviceInterfaceDetailW(interfaces,&interfaceData,nullptr,0,&size,nullptr);
            if(size<sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W) || size>65536){interfaceError=ERROR_INSUFFICIENT_BUFFER;break;}
            std::vector<unsigned char> storage(size); auto detail=reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
            detail->cbSize=sizeof(*detail); SP_DEVINFO_DATA device{};device.cbSize=sizeof(device);
            if(!SetupDiGetDeviceInterfaceDetailW(interfaces,&interfaceData,detail,size,nullptr,&device)){interfaceError=GetLastError();break;}
            wchar_t instance[4096]{},friendly[4096]{};DWORD needed=0;DEVPROPTYPE type=0;DWORD friendlyError=ERROR_PROC_NOT_FOUND;
            if(!SetupDiGetDeviceInstanceIdW(interfaces,&device,instance,4096,&needed)) instance[0]=0;
            if(getProperty){if(getProperty(interfaces,&interfaceData,&friendlyKey,&type,reinterpret_cast<PBYTE>(friendly),sizeof(friendly)-sizeof(wchar_t),&needed,0) && type==DEVPROP_TYPE_STRING) friendlyError=ERROR_SUCCESS;else {friendlyError=GetLastError();friendly[0]=0;}}
            friendly[4095]=0;
            std::printf("%s{\"path\":\"%s\",\"instanceId\":\"%s\",\"deviceDesc\":\"%s\",\"hardwareId\":\"%s\",\"friendlyName\":\"%s\",\"friendlyError\":%lu}",
                interfaceCount?",":"",json(detail->DevicePath).c_str(),json(instance).c_str(),prop(interfaces,&device,SPDRP_DEVICEDESC).c_str(),prop(interfaces,&device,SPDRP_HARDWAREID).c_str(),json(friendly).c_str(),static_cast<unsigned long>(friendlyError));
            ++interfaceCount;
        }
        SetupDiDestroyDeviceInfoList(interfaces);
    }
    const bool interfacesComplete=interfacesOK && interfaceError==ERROR_NO_MORE_ITEMS;
    std::printf("],\"interfacesComplete\":%s,\"interfacesError\":%lu,\"interfaceCount\":%u,\"interfacePropertyAvailable\":%s}\n",interfacesComplete?"true":"false",static_cast<unsigned long>(interfaceError),interfaceCount,getProperty?"true":"false");
    return complete && interfacesComplete?0:1;
}
