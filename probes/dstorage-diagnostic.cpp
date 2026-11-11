// Source-only diagnostic. Requires Microsoft's DirectStorage 1.2.2 SDK dstorage.h.
// Run only with an explicitly approved absolute DLL path and nonce. This does not
// submit requests or open game assets; loading a DLL executes its initialization.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dstorage.h>
#include <dxgi1_4.h>
#include <cstdio>
#include <cstddef>
#include <string>

static_assert(sizeof(DSTORAGE_QUEUE_DESC) == 32 && offsetof(DSTORAGE_QUEUE_DESC, Capacity) == 8 &&
              offsetof(DSTORAGE_QUEUE_DESC, Priority) == 10 && offsetof(DSTORAGE_QUEUE_DESC, Name) == 16 &&
              offsetof(DSTORAGE_QUEUE_DESC, Device) == 24, "DirectStorage queue descriptor ABI mismatch");
// DirectStorage 1.2.2 SDK dstorage.h declares these interface UUIDs. MinGW
// does not provide __mingw_uuidof specializations for the SDK declarations.
static constexpr GUID factory_iid = {0x6924ea0c,0xc3cd,0x4826,{0xb1,0x0a,0xf6,0x4f,0x4e,0xd9,0x27,0xc1}};
static constexpr GUID queue_iid = {0xcfdbd83f,0x9e06,0x4fda,{0x8e,0xa5,0x69,0x04,0x21,0x37,0xf4,0x9b}};
static constexpr GUID dxgi_factory_iid = {0x770aae78,0xf26f,0x4dba,{0xa8,0x29,0x25,0x3c,0x83,0xd1,0xb3,0x87}};
static constexpr GUID d3d_device_iid = {0x189819f1,0x1db6,0x4b57,{0xbe,0x54,0x18,0x21,0x33,0x9b,0x85,0xf7}};

static std::string utf8(const wchar_t *s) {
    if (!s) return {};
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s, -1, nullptr, 0, nullptr, nullptr);
    if (!n) return {};
    std::string out(static_cast<size_t>(n), '\0');
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s, -1, &out[0], n, nullptr, nullptr)) return {};
    out.pop_back();
    return out;
}
static void json_string(const std::string &s) {
    std::putchar('"');
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') std::printf("\\%c", c);
        else if (c < 0x20) std::printf("\\u%04x", static_cast<unsigned>(c));
        else std::putchar(c);
    }
    std::putchar('"');
}
static bool absolute_path(const wchar_t *s) {
    return s && ((s[0] && s[1] == L':' && (s[2] == L'\\' || s[2] == L'/')) ||
                 (s[0] == L'\\' && s[1] == L'\\'));
}
static void module_path(HMODULE module) {
    if (!module) { std::printf("{\"present\":false}"); return; }
    wchar_t path[32768];
    SetLastError(ERROR_SUCCESS);
    DWORD n = GetModuleFileNameW(module, path, static_cast<DWORD>(sizeof(path) / sizeof(*path)));
    DWORD error = n ? ERROR_SUCCESS : GetLastError();
    std::printf("{\"present\":true,\"win32_error\":%lu,\"path\":", static_cast<unsigned long>(error));
    if (!n || n >= sizeof(path) / sizeof(*path)) std::printf("null");
    else json_string(utf8(path));
    std::putchar('}');
}
int wmain(int argc, wchar_t **argv) {
    if ((argc != 3 && argc != 4) || !absolute_path(argv[1]) || (argc == 4 && std::wcscmp(argv[3], L"--gpu"))) {
        std::fprintf(stderr, "usage: dstorage-diagnostic ABSOLUTE_DLL_PATH ASCII_NONCE [--gpu]\n");
        return 2;
    }
    std::string nonce = utf8(argv[2]);
    if (nonce.empty() || nonce.size() > 128) return 2;
    for (unsigned char c : nonce) if (c < 0x21 || c > 0x7e) return 2;

    SetLastError(ERROR_SUCCESS);
    HMODULE dll = LoadLibraryExW(argv[1], nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    DWORD load_error = dll ? ERROR_SUCCESS : GetLastError();
    FARPROC symbol = nullptr;
    DWORD symbol_error = ERROR_SUCCESS;
    HRESULT factory_hr = E_FAIL, queue_hr = E_FAIL;
    bool factory_called = false, queue_called = false;
    IDStorageFactory *factory = nullptr;
    IDStorageQueue *queue = nullptr;
    if (dll) {
        SetLastError(ERROR_SUCCESS);
        symbol = GetProcAddress(dll, "DStorageGetFactory");
        if (!symbol) symbol_error = GetLastError();
        if (symbol) {
            using GetFactory = HRESULT (WINAPI *)(REFIID, void **);
            factory_called = true;
            factory_hr = reinterpret_cast<GetFactory>(symbol)(factory_iid, reinterpret_cast<void **>(&factory));
            if (SUCCEEDED(factory_hr) && factory) {
                DSTORAGE_QUEUE_DESC desc{};
                desc.SourceType = DSTORAGE_REQUEST_SOURCE_FILE;
                desc.Capacity = DSTORAGE_MIN_QUEUE_CAPACITY;
                desc.Priority = DSTORAGE_PRIORITY_NORMAL;
                desc.Device = nullptr; // A null device permits memory destinations only.
                queue_called = true;
                queue_hr = factory->CreateQueue(&desc, queue_iid, reinterpret_cast<void **>(&queue));
            }
        }
    }
    const bool cpu_queue_nonnull = queue != nullptr;
    if (queue) { queue->Release(); queue = nullptr; }
    // Opt-in only. The adapter is selected by the exact four fields observed
    // for this game, not by fabricated capabilities or a software fallback.
    const bool gpu_requested = argc == 4;
    HMODULE dxgi = nullptr, d3d12 = nullptr;
    IDXGIFactory1 *dxgi_factory = nullptr;
    IDXGIAdapter1 *selected_adapter = nullptr;
    ID3D12Device *device = nullptr;
    IDStorageQueue *gpu_queue = nullptr;
    DXGI_ADAPTER_DESC1 selected{};
    HRESULT dxgi_hr = E_FAIL, enum_hr = E_FAIL, device_hr = E_FAIL, gpu_queue_hr = E_FAIL;
    bool dxgi_symbol = false, device_symbol = false, dxgi_called = false, enum_complete = false, device_called = false, gpu_queue_called = false;
    unsigned matches = 0;
    if (gpu_requested) {
        dxgi = LoadLibraryW(L"dxgi.dll");
        d3d12 = LoadLibraryW(L"d3d12.dll");
        using CreateFactory = HRESULT (WINAPI *)(REFIID, void **);
        using CreateDevice = HRESULT (WINAPI *)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
        auto make_factory = dxgi ? reinterpret_cast<CreateFactory>(GetProcAddress(dxgi, "CreateDXGIFactory1")) : nullptr;
        auto make_device = d3d12 ? reinterpret_cast<CreateDevice>(GetProcAddress(d3d12, "D3D12CreateDevice")) : nullptr;
        dxgi_symbol = make_factory != nullptr; device_symbol = make_device != nullptr;
        if (make_factory) {
            dxgi_called = true;
            dxgi_hr = make_factory(dxgi_factory_iid, reinterpret_cast<void **>(&dxgi_factory));
        }
        if (SUCCEEDED(dxgi_hr) && dxgi_factory) {
            for (UINT i = 0; i < 32; ++i) {
                IDXGIAdapter1 *adapter = nullptr;
                enum_hr = dxgi_factory->EnumAdapters1(i, &adapter);
                if (enum_hr == DXGI_ERROR_NOT_FOUND) { enum_complete = true; break; }
                if (FAILED(enum_hr) || !adapter) break;
                DXGI_ADAPTER_DESC1 desc{};
                HRESULT desc_hr = adapter->GetDesc1(&desc);
                if (FAILED(desc_hr)) { enum_hr = desc_hr; adapter->Release(); break; }
                if (!(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) && desc.VendorId == 0x1002 &&
                    desc.DeviceId == 0x66af && desc.SubSysId == 0 && desc.Revision == 0) {
                    ++matches;
                    if (matches == 1) { selected_adapter = adapter; selected = desc; adapter = nullptr; }
                }
                if (adapter) adapter->Release();
            }
        }
        if (enum_complete && matches == 1 && selected_adapter && make_device) {
            device_called = true;
            device_hr = make_device(selected_adapter, D3D_FEATURE_LEVEL_11_0, d3d_device_iid, reinterpret_cast<void **>(&device));
        }
        if (SUCCEEDED(factory_hr) && factory && SUCCEEDED(device_hr) && device) {
            DSTORAGE_QUEUE_DESC desc{};
            desc.SourceType = DSTORAGE_REQUEST_SOURCE_FILE;
            desc.Capacity = DSTORAGE_MIN_QUEUE_CAPACITY;
            desc.Priority = DSTORAGE_PRIORITY_NORMAL;
            desc.Device = device;
            gpu_queue_called = true;
            gpu_queue_hr = factory->CreateQueue(&desc, queue_iid, reinterpret_cast<void **>(&gpu_queue));
        }
    }
    HMODULE core = GetModuleHandleW(L"dstoragecore.dll");
    std::printf("{\"schema\":1,\"kind\":\"playmelt-dstorage-probe\",\"nonce\":"); json_string(nonce);
    std::printf(",\"sdk_target\":\"DirectStorage 1.2.2\",\"load\":{\"ok\":%s,\"win32_error\":%lu,\"module\":", dll ? "true" : "false", static_cast<unsigned long>(load_error));
    module_path(dll);
    std::printf("},\"core\":"); module_path(core);
    std::printf(",\"get_factory_symbol\":{\"found\":%s,\"win32_error\":", symbol ? "true" : "false");
    if (dll) std::printf("%lu", static_cast<unsigned long>(symbol_error)); else std::printf("null");
    std::printf("},\"get_factory\":{\"called\":%s,\"hresult\":", factory_called ? "true" : "false");
    if (factory_called) std::printf("\"0x%08lX\"", static_cast<unsigned long>(static_cast<unsigned int>(factory_hr))); else std::printf("null");
    std::printf(",\"object_nonnull\":%s},\"create_file_to_memory_queue\":{\"called\":%s,\"hresult\":", factory ? "true" : "false", queue_called ? "true" : "false");
    if (queue_called) std::printf("\"0x%08lX\"", static_cast<unsigned long>(static_cast<unsigned int>(queue_hr))); else std::printf("null");
    std::printf(",\"object_nonnull\":%s},\"gpu\":{\"requested\":%s,\"dxgi_module\":", cpu_queue_nonnull ? "true" : "false", gpu_requested ? "true" : "false");
    module_path(dxgi); std::printf(",\"d3d12_module\":"); module_path(d3d12);
    std::printf(",\"dxgi_factory_symbol\":%s,\"d3d12_create_device_symbol\":%s,\"dxgi_factory\":{\"called\":%s,\"hresult\":", dxgi_symbol ? "true" : "false", device_symbol ? "true" : "false", dxgi_called ? "true" : "false");
    if (dxgi_called) std::printf("\"0x%08lX\"", static_cast<unsigned long>(static_cast<unsigned int>(dxgi_hr))); else std::printf("null");
    std::printf(",\"object_nonnull\":%s},\"adapter\":{\"enumeration_complete\":%s,\"matches\":%u,\"enum_hresult\":", dxgi_factory ? "true" : "false", enum_complete ? "true" : "false", matches);
    if (dxgi_factory) std::printf("\"0x%08lX\"", static_cast<unsigned long>(static_cast<unsigned int>(enum_hr))); else std::printf("null");
    std::printf(",\"vendor_id\":%u,\"device_id\":%u,\"subsystem_id\":%u,\"revision\":%u,\"flags\":%u,\"luid_high\":%ld,\"luid_low\":%lu},\"device\":{\"called\":%s,\"minimum_feature_level\":\"11_0\",\"hresult\":", selected.VendorId, selected.DeviceId, selected.SubSysId, selected.Revision, selected.Flags, static_cast<long>(selected.AdapterLuid.HighPart), static_cast<unsigned long>(selected.AdapterLuid.LowPart), device_called ? "true" : "false");
    if (device_called) std::printf("\"0x%08lX\"", static_cast<unsigned long>(static_cast<unsigned int>(device_hr))); else std::printf("null");
    std::printf(",\"object_nonnull\":%s},\"create_file_to_gpu_queue\":{\"called\":%s,\"hresult\":", device ? "true" : "false", gpu_queue_called ? "true" : "false");
    if (gpu_queue_called) std::printf("\"0x%08lX\"", static_cast<unsigned long>(static_cast<unsigned int>(gpu_queue_hr))); else std::printf("null");
    std::printf(",\"object_nonnull\":%s}}}\n", gpu_queue ? "true" : "false");
    if (gpu_queue) gpu_queue->Release();
    if (device) device->Release();
    if (selected_adapter) selected_adapter->Release();
    if (dxgi_factory) dxgi_factory->Release();
    if (queue) queue->Release();
    if (factory) factory->Release();
    if (dll) FreeLibrary(dll);
    if (d3d12) FreeLibrary(d3d12);
    if (dxgi) FreeLibrary(dxgi);
    return 0;
}
