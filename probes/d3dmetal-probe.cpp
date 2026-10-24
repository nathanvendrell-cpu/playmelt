// FUTURE OPT-IN PROBE; not built or executed by import. Windows x86_64 SDK required.
// The native runner must obtain GPU-test authorization, use an initialized idle
// D3DMetal-only prefix, bind executable/renderer/engine hashes and nonce, enforce
// a timeout, and reap its own Wine tree. It must independently observe the exact
// imported D3DMetal.framework image in the host process (for example bounded
// DYLD_PRINT_LIBRARIES output). stdout booleans alone are not accepted evidence.
// Device creation proves only this loader/device path, never game performance.
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <cstdio>
#include <cstring>
#include <cctype>
#include <string>

static std::string moduleJSON(HMODULE module) {
    wchar_t path[4096]{};
    DWORD size = module ? GetModuleFileNameW(module, path, 4096) : 0;
    if (!size || size >= 4096) return "";
    int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, size, nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) return "";
    std::string utf8(bytes, '\0'), escaped;
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, size, &utf8[0], bytes, nullptr, nullptr);
    for (unsigned char c : utf8) {
        if (c == '\\' || c == '"') { escaped += '\\'; escaped += char(c); }
        else if (c < 32) { char value[7]; std::snprintf(value, sizeof value, "\\u%04x", c); escaped += value; }
        else escaped += char(c);
    }
    return escaped;
}
int main(int argc, char **argv) {
    if (argc != 3 || std::strcmp(argv[1], "--nonce") || std::strlen(argv[2]) != 36) return 64;
    for (const char *p = argv[2]; *p; ++p) if (!std::isxdigit(static_cast<unsigned char>(*p)) && *p != '-') return 64;
    HMODULE dxgi = LoadLibraryW(L"dxgi.dll"), d3d12 = LoadLibraryW(L"d3d12.dll");
    using CreateFactory = HRESULT (WINAPI *)(REFIID, void **);
    using CreateDevice = HRESULT (WINAPI *)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
    auto factoryFunction = dxgi ? reinterpret_cast<CreateFactory>(GetProcAddress(dxgi, "CreateDXGIFactory1")) : nullptr;
    auto create = d3d12 ? reinterpret_cast<CreateDevice>(GetProcAddress(d3d12, "D3D12CreateDevice")) : nullptr;
    const GUID factoryIID = {0x770aae78,0xf26f,0x4dba,{0xa8,0x29,0x25,0x3c,0x83,0xd1,0xb3,0x87}};
    const GUID deviceIID = {0x189819f1,0x1db6,0x4b57,{0xbe,0x54,0x18,0x21,0x33,0x9b,0x85,0xf7}};
    IDXGIFactory1 *factory = nullptr;
    ID3D12Device *device = nullptr;
    DXGI_ADAPTER_DESC1 selected{};
    selected.Flags = DXGI_ADAPTER_FLAG_SOFTWARE;
    HRESULT result = E_NOINTERFACE;
    if (factoryFunction && create && SUCCEEDED(factoryFunction(factoryIID, reinterpret_cast<void **>(&factory)))) {
        for (UINT i = 0; i < 32 && !device; ++i) {
            IDXGIAdapter1 *adapter = nullptr;
            if (factory->EnumAdapters1(i, &adapter) != S_OK) break;
            DXGI_ADAPTER_DESC1 description{};
            if (SUCCEEDED(adapter->GetDesc1(&description)) && !(description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) {
                result = create(adapter, D3D_FEATURE_LEVEL_12_0, deviceIID, reinterpret_cast<void **>(&device));
                if (SUCCEEDED(result) && device) selected = description;
            }
            adapter->Release();
        }
    }
    const bool created = result == S_OK && device;
    const std::string dxgiPath = moduleJSON(dxgi), d3d12Path = moduleJSON(d3d12);
    std::printf("{\"schema\":1,\"kind\":\"playmelt-d3d12-probe\",\"nonce\":\"%s\",\"dxgiLoaded\":%s,\"d3d12Loaded\":%s,\"dxgiModule\":\"%s\",\"d3d12Module\":\"%s\",\"deviceCreated\":%s,\"featureLevel\":\"12_0\",\"hresult\":%ld,\"adapterFlags\":%u,\"adapterVendorID\":%u}\n",
                argv[2], dxgi ? "true" : "false", d3d12 ? "true" : "false", dxgiPath.c_str(), d3d12Path.c_str(), created ? "true" : "false", static_cast<long>(result), selected.Flags, selected.VendorId);
    if (device) device->Release();
    if (factory) factory->Release();
    if (d3d12) FreeLibrary(d3d12);
    if (dxgi) FreeLibrary(dxgi);
    return created && !dxgiPath.empty() && !d3d12Path.empty() ? 0 : 1;
}
