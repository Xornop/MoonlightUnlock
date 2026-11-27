// Moonlight Unlock - Windows Credential Provider
// Reads the controller (XInput) on the lock/sign-in screen. With the right button combo
// (within 10 s) and an active controller (= Moonlight stream) it signs in/unlocks automatically.

#define WIN32_NO_STATUS
#include <windows.h>
#undef WIN32_NO_STATUS
#include <ntstatus.h>
#include <unknwn.h>
#include <ntsecapi.h>
#include <credentialprovider.h>
#include <shlwapi.h>
#include <wincrypt.h>
#include <sddl.h>
#include <xinput.h>
#include <string>
#include <vector>
#include <deque>
#include <ctime>
#include <cstdio>

// {7B1A3E2C-4F5D-4C8A-9E21-5A6D0B831CF4}
static const GUID CLSID_MoonlightUnlock =
    { 0x7b1a3e2c, 0x4f5d, 0x4c8a, { 0x9e, 0x21, 0x5a, 0x6d, 0x0b, 0x83, 0x1c, 0xf4 } };

static const wchar_t* kDataDir   = L"C:\\ProgramData\\MoonlightUnlock";
static const wchar_t* kSecret    = L"C:\\ProgramData\\MoonlightUnlock\\secret.bin";
static const wchar_t* kFlag      = L"C:\\ProgramData\\MoonlightUnlock\\unlocked.flag";
static const wchar_t* kLog       = L"C:\\ProgramData\\MoonlightUnlock\\cp.log";
static const DWORD    kWindowMs  = 10000;   // first to last button

static LONG      g_cRef  = 0;
static HINSTANCE g_hinst = nullptr;
static volatile LONG g_unlock = 0;          // 1 = combo recognised, waiting for serialization

// ---------------------------------------------------------------- protected files
// Only SYSTEM and Administrators may write anything in kDataDir. Standard users may only read
// the folder itself (not inherited), so they can't plant or replace files that this DLL opens
// (as SYSTEM), and can't read secret.bin.
static const wchar_t* kDirSddl  = L"O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200a9;;;BU)";
// The lock-watcher (running as your user) must be able to read the flag.
static const wchar_t* kFlagSddl = L"O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)";

struct SecAttr {
    SECURITY_ATTRIBUTES sa = { sizeof(SECURITY_ATTRIBUTES), nullptr, FALSE };
    explicit SecAttr(const wchar_t* sddl)
    {
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, &sa.lpSecurityDescriptor, nullptr))
            sa.lpSecurityDescriptor = nullptr;
    }
    ~SecAttr() { if (sa.lpSecurityDescriptor) LocalFree(sa.lpSecurityDescriptor); }
    bool ok() const { return sa.lpSecurityDescriptor != nullptr; }
};

// Creates the folder only if it doesn't exist yet, and then right away with the correct ACL
// (never with the default ProgramData permissions, which let Users create files).
static void EnsureDataDir()
{
    if (GetFileAttributesW(kDataDir) != INVALID_FILE_ATTRIBUTES) return;
    SecAttr sa(kDirSddl);
    if (sa.ok()) CreateDirectoryW(kDataDir, &sa.sa);
}

// ---------------------------------------------------------------- logging
static void Log(const char* fmt, ...)
{
    char msg[512];
    va_list ap; va_start(ap, fmt);
    _vsnprintf(msg, sizeof(msg) - 1, fmt, ap);
    va_end(ap);
    msg[sizeof(msg) - 1] = 0;

    SYSTEMTIME st; GetLocalTime(&st);
    char line[640];
    int n = _snprintf(line, sizeof(line) - 1, "%04d-%02d-%02d %02d:%02d:%02d.%03d %s\r\n",
                      st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, msg);
    if (n <= 0) return;
    EnsureDataDir();
    HANDLE h = CreateFileW(kLog, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    DWORD w; WriteFile(h, line, (DWORD)n, &w, nullptr);
    CloseHandle(h);
}

// ---------------------------------------------------------------- XInput (loaded dynamically)
typedef DWORD (WINAPI* PFN_GetState)(DWORD, XINPUT_STATE*);
static PFN_GetState g_getState = nullptr;

static void LoadXInput()
{
    if (g_getState) return;
    HMODULE m = LoadLibraryW(L"xinput1_4.dll");
    if (!m) m = LoadLibraryW(L"xinput9_1_0.dll");
    if (m) g_getState = (PFN_GetState)GetProcAddress(m, "XInputGetState");
    if (!g_getState) Log("XInput not available");
}

// Returns true if a controller is present; mask = OR of all pressed buttons
static bool ReadPads(WORD* mask)
{
    *mask = 0;
    if (!g_getState) return false;
    bool any = false;
    for (DWORD i = 0; i < 4; i++) {
        XINPUT_STATE s;
        if (g_getState(i, &s) == ERROR_SUCCESS) {
            any = true;
            *mask |= s.Gamepad.wButtons;
        }
    }
    return any;
}

// ---------------------------------------------------------------- configuration (DPAPI, machine scope)
struct Config {
    std::wstring domain, user, password;
    std::vector<WORD> combo;
};

static bool ReadAll(const wchar_t* path, std::vector<BYTE>& out)
{
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER sz; bool ok = false;
    if (GetFileSizeEx(h, &sz) && sz.QuadPart > 0 && sz.QuadPart < 65536) {
        out.resize((size_t)sz.QuadPart);
        DWORD r = 0;
        ok = ReadFile(h, out.data(), (DWORD)out.size(), &r, nullptr) && r == out.size();
    }
    CloseHandle(h);
    return ok;
}

static bool LoadConfig(Config& c)
{
    std::vector<BYTE> blob;
    if (!ReadAll(kSecret, blob)) { Log("secret.bin not readable"); return false; }

    DATA_BLOB in = { (DWORD)blob.size(), blob.data() }, out = {};
    if (!CryptUnprotectData(&in, nullptr, nullptr, nullptr, nullptr, 0, &out)) {
        Log("CryptUnprotectData failed (%lu)", GetLastError());
        return false;
    }
    std::string text((char*)out.pbData, out.cbData);
    SecureZeroMemory(out.pbData, out.cbData);
    LocalFree(out.pbData);

    // lines: domain, user, password, combo (hex, comma-separated)
    std::vector<std::string> lines;
    size_t pos = 0;
    while (pos <= text.size()) {
        size_t e = text.find('\n', pos);
        if (e == std::string::npos) e = text.size();
        std::string l = text.substr(pos, e - pos);
        if (!l.empty() && l.back() == '\r') l.pop_back();
        lines.push_back(l);
        pos = e + 1;
    }
    SecureZeroMemory(&text[0], text.size());
    if (lines.size() < 4) { Log("secret.bin has an unexpected format"); return false; }

    auto wide = [](const std::string& s) {
        if (s.empty()) return std::wstring();
        int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
        std::wstring w(n, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
        return w;
    };
    c.domain = wide(lines[0]);
    c.user = wide(lines[1]);
    c.password = wide(lines[2]);
    for (auto& ch : lines[2]) ch = 0;

    c.combo.clear();
    size_t p = 0;
    const std::string& cs = lines[3];
    while (p < cs.size()) {
        size_t e = cs.find(',', p);
        if (e == std::string::npos) e = cs.size();
        c.combo.push_back((WORD)strtoul(cs.substr(p, e - p).c_str(), nullptr, 16));
        p = e + 1;
    }
    if (c.combo.size() < 4) { Log("combo invalid/too short"); return false; }
    return true;
}

static void WipeConfig(Config& c)
{
    if (!c.password.empty()) SecureZeroMemory(&c.password[0], c.password.size() * sizeof(wchar_t));
    c.password.clear();
}

// ---------------------------------------------------------------- flag for the lock-watcher
static void ClearFlag()
{
    DeleteFileW(kFlag);
}

static void WriteFlag()
{
    // Always a new file, so the ACL below applies (CREATE_ALWAYS would keep an old ACL).
    ClearFlag();
    SecAttr sa(kFlagSddl);
    if (!sa.ok()) return;
    HANDLE h = CreateFileW(kFlag, GENERIC_WRITE, FILE_SHARE_READ, &sa.sa, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    char buf[32];
    int n = _snprintf(buf, sizeof(buf) - 1, "%lld", (long long)time(nullptr));
    DWORD w; WriteFile(h, buf, (DWORD)n, &w, nullptr);
    CloseHandle(h);
}

// ---------------------------------------------------------------- serialization
static HRESULT PackCredentials(const Config& c, CREDENTIAL_PROVIDER_USAGE_SCENARIO cpus, BYTE** ppb, DWORD* pcb)
{
    size_t cbDom = c.domain.size() * sizeof(WCHAR);
    size_t cbUsr = c.user.size() * sizeof(WCHAR);
    size_t cbPwd = c.password.size() * sizeof(WCHAR);
    DWORD cb = (DWORD)(sizeof(KERB_INTERACTIVE_UNLOCK_LOGON) + cbDom + cbUsr + cbPwd);

    BYTE* pb = (BYTE*)CoTaskMemAlloc(cb);
    if (!pb) return E_OUTOFMEMORY;
    ZeroMemory(pb, cb);

    KERB_INTERACTIVE_UNLOCK_LOGON* p = (KERB_INTERACTIVE_UNLOCK_LOGON*)pb;
    p->Logon.MessageType = (cpus == CPUS_UNLOCK_WORKSTATION) ? KerbWorkstationUnlockLogon : KerbInteractiveLogon;

    BYTE* cur = pb + sizeof(KERB_INTERACTIVE_UNLOCK_LOGON);
    auto put = [&](UNICODE_STRING& us, const std::wstring& s) {
        us.Length = us.MaximumLength = (USHORT)(s.size() * sizeof(WCHAR));
        us.Buffer = (PWSTR)(ULONG_PTR)(cur - pb);          // offset from the start of the structure
        if (!s.empty()) memcpy(cur, s.data(), us.Length);
        cur += us.Length;
    };
    put(p->Logon.LogonDomainName, c.domain);
    put(p->Logon.UserName, c.user);
    put(p->Logon.Password, c.password);

    *ppb = pb; *pcb = cb;
    return S_OK;
}

static HRESULT NegotiatePackage(ULONG* pulPackage)
{
    HANDLE h = nullptr;
    NTSTATUS st = LsaConnectUntrusted(&h);
    if (st != STATUS_SUCCESS) return HRESULT_FROM_WIN32(LsaNtStatusToWinError(st));
    static char name[] = "Negotiate";
    LSA_STRING ls; ls.Buffer = name; ls.Length = (USHORT)strlen(name); ls.MaximumLength = ls.Length + 1;
    ULONG pkg = 0;
    st = LsaLookupAuthenticationPackage(h, &ls, &pkg);
    LsaDeregisterLogonProcess(h);
    if (st != STATUS_SUCCESS) return HRESULT_FROM_WIN32(LsaNtStatusToWinError(st));
    *pulPackage = pkg;
    return S_OK;
}

// ---------------------------------------------------------------- Provider
class CProvider;

class CCredential : public ICredentialProviderCredential
{
public:
    CCredential(CProvider* prov, CREDENTIAL_PROVIDER_USAGE_SCENARIO cpus) : _ref(1), _prov(prov), _cpus(cpus) {}
    virtual ~CCredential() {}

    // IUnknown
    IFACEMETHODIMP_(ULONG) AddRef() { return InterlockedIncrement(&_ref); }
    IFACEMETHODIMP_(ULONG) Release() { LONG r = InterlockedDecrement(&_ref); if (!r) delete this; return r; }
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv)
    {
        if (riid == IID_IUnknown || riid == IID_ICredentialProviderCredential) {
            *ppv = static_cast<ICredentialProviderCredential*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    // ICredentialProviderCredential
    IFACEMETHODIMP Advise(ICredentialProviderCredentialEvents*) { return E_NOTIMPL; }
    IFACEMETHODIMP UnAdvise() { return E_NOTIMPL; }
    IFACEMETHODIMP SetSelected(BOOL* pbAutoLogon);
    IFACEMETHODIMP SetDeselected() { return S_OK; }
    IFACEMETHODIMP GetFieldState(DWORD dwFieldID, CREDENTIAL_PROVIDER_FIELD_STATE* pcpfs, CREDENTIAL_PROVIDER_FIELD_INTERACTIVE_STATE* pcpfis)
    {
        *pcpfis = CPFIS_NONE;
        if (dwFieldID == 0) { *pcpfs = CPFS_DISPLAY_IN_BOTH; return S_OK; }
        if (dwFieldID == 1) { *pcpfs = CPFS_DISPLAY_IN_SELECTED_TILE; return S_OK; }
        return E_INVALIDARG;
    }
    IFACEMETHODIMP GetStringValue(DWORD dwFieldID, PWSTR* ppsz)
    {
        if (dwFieldID == 0) return SHStrDupW(L"Moonlight: enter your button combo", ppsz);
        return E_INVALIDARG;
    }
    IFACEMETHODIMP GetBitmapValue(DWORD, HBITMAP*) { return E_NOTIMPL; }
    IFACEMETHODIMP GetCheckboxValue(DWORD, BOOL*, PWSTR*) { return E_NOTIMPL; }
    IFACEMETHODIMP GetSubmitButtonValue(DWORD dwFieldID, DWORD* pdwAdjacentTo)
    {
        if (dwFieldID == 1) { *pdwAdjacentTo = 0; return S_OK; }
        return E_INVALIDARG;
    }
    IFACEMETHODIMP GetComboBoxValueCount(DWORD, DWORD*, DWORD*) { return E_NOTIMPL; }
    IFACEMETHODIMP GetComboBoxValueAt(DWORD, DWORD, PWSTR*) { return E_NOTIMPL; }
    IFACEMETHODIMP SetStringValue(DWORD, PCWSTR) { return E_NOTIMPL; }
    IFACEMETHODIMP SetCheckboxValue(DWORD, BOOL) { return E_NOTIMPL; }
    IFACEMETHODIMP SetComboBoxSelectedValue(DWORD, DWORD) { return E_NOTIMPL; }
    IFACEMETHODIMP CommandLinkClicked(DWORD) { return E_NOTIMPL; }
    IFACEMETHODIMP GetSerialization(CREDENTIAL_PROVIDER_GET_SERIALIZATION_RESPONSE* pcpgsr,
                                    CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* pcpcs,
                                    PWSTR* ppszOptionalStatusText,
                                    CREDENTIAL_PROVIDER_STATUS_ICON* pcpsiOptionalStatusIcon);
    IFACEMETHODIMP ReportResult(NTSTATUS ntsStatus, NTSTATUS ntsSubstatus, PWSTR*, CREDENTIAL_PROVIDER_STATUS_ICON*)
    {
        Log("ReportResult status=0x%08lx substatus=0x%08lx", (unsigned long)ntsStatus, (unsigned long)ntsSubstatus);
        InterlockedExchange(&g_unlock, 0);
        return S_OK;
    }

private:
    LONG _ref;
    CProvider* _prov;
    CREDENTIAL_PROVIDER_USAGE_SCENARIO _cpus;
};

class CProvider : public ICredentialProvider
{
public:
    CProvider() : _ref(1), _cpus(CPUS_INVALID), _events(nullptr), _ctx(0), _thread(nullptr), _stop(nullptr)
    {
        InterlockedIncrement(&g_cRef);
        InitializeCriticalSection(&_cs);
    }
    virtual ~CProvider()
    {
        StopThread();
        if (_events) { _events->Release(); _events = nullptr; }
        DeleteCriticalSection(&_cs);
        InterlockedDecrement(&g_cRef);
    }

    // IUnknown
    IFACEMETHODIMP_(ULONG) AddRef() { return InterlockedIncrement(&_ref); }
    IFACEMETHODIMP_(ULONG) Release() { LONG r = InterlockedDecrement(&_ref); if (!r) delete this; return r; }
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv)
    {
        if (riid == IID_IUnknown || riid == IID_ICredentialProvider) {
            *ppv = static_cast<ICredentialProvider*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    // ICredentialProvider
    IFACEMETHODIMP SetUsageScenario(CREDENTIAL_PROVIDER_USAGE_SCENARIO cpus, DWORD)
    {
        if (cpus != CPUS_LOGON && cpus != CPUS_UNLOCK_WORKSTATION) return E_NOTIMPL;
        _cpus = cpus;
        InterlockedExchange(&g_unlock, 0);
        // The lock/sign-in screen is showing: any earlier combo unlock is over.
        ClearFlag();
        LoadXInput();
        StartThread();
        Log("SetUsageScenario %d", (int)cpus);
        return S_OK;
    }
    IFACEMETHODIMP SetSerialization(const CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION*) { return E_NOTIMPL; }
    IFACEMETHODIMP Advise(ICredentialProviderEvents* pcpe, UINT_PTR ctx)
    {
        EnterCriticalSection(&_cs);
        if (_events) _events->Release();
        _events = pcpe; _events->AddRef(); _ctx = ctx;
        LeaveCriticalSection(&_cs);
        return S_OK;
    }
    IFACEMETHODIMP UnAdvise()
    {
        EnterCriticalSection(&_cs);
        if (_events) { _events->Release(); _events = nullptr; }
        LeaveCriticalSection(&_cs);
        return S_OK;
    }
    IFACEMETHODIMP GetFieldDescriptorCount(DWORD* pdwCount) { *pdwCount = 2; return S_OK; }
    IFACEMETHODIMP GetFieldDescriptorAt(DWORD dwIndex, CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR** ppcpfd)
    {
        if (dwIndex > 1) return E_INVALIDARG;
        auto* d = (CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR*)CoTaskMemAlloc(sizeof(CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR));
        if (!d) return E_OUTOFMEMORY;
        ZeroMemory(d, sizeof(*d));
        d->dwFieldID = dwIndex;
        d->cpft = (dwIndex == 0) ? CPFT_LARGE_TEXT : CPFT_SUBMIT_BUTTON;
        HRESULT hr = SHStrDupW(dwIndex == 0 ? L"Moonlight" : L"Unlock", &d->pszLabel);
        if (FAILED(hr)) { CoTaskMemFree(d); return hr; }
        *ppcpfd = d;
        return S_OK;
    }
    IFACEMETHODIMP GetCredentialCount(DWORD* pdwCount, DWORD* pdwDefault, BOOL* pbAutoLogonWithDefault)
    {
        *pdwCount = 1;
        if (InterlockedCompareExchange(&g_unlock, 0, 0)) {
            *pdwDefault = 0;
            *pbAutoLogonWithDefault = TRUE;
        } else {
            *pdwDefault = CREDENTIAL_PROVIDER_NO_DEFAULT;
            *pbAutoLogonWithDefault = FALSE;
        }
        return S_OK;
    }
    IFACEMETHODIMP GetCredentialAt(DWORD dwIndex, ICredentialProviderCredential** ppcpc)
    {
        if (dwIndex != 0) return E_INVALIDARG;
        *ppcpc = new (std::nothrow) CCredential(this, _cpus);
        return *ppcpc ? S_OK : E_OUTOFMEMORY;
    }

private:
    static DWORD WINAPI ThreadProc(LPVOID p) { ((CProvider*)p)->Run(); return 0; }

    void StartThread()
    {
        if (_thread) return;
        _stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        _thread = CreateThread(nullptr, 0, ThreadProc, this, 0, nullptr);
    }
    void StopThread()
    {
        if (!_thread) return;
        SetEvent(_stop);
        WaitForSingleObject(_thread, 3000);
        CloseHandle(_thread); _thread = nullptr;
        CloseHandle(_stop); _stop = nullptr;
    }

    void Run()
    {
        Config cfg;
        if (!LoadConfig(cfg)) { Log("combo thread stopping: no configuration"); return; }
        std::vector<WORD> combo = cfg.combo;
        WipeConfig(cfg);
        Log("combo thread started (%u buttons)", (unsigned)combo.size());

        struct Press { DWORD t; WORD m; };
        std::deque<Press> presses;
        WORD prev = 0;

        while (WaitForSingleObject(_stop, 20) == WAIT_TIMEOUT) {
            WORD mask = 0;
            bool present = ReadPads(&mask);
            if (!present) { presses.clear(); prev = 0; continue; }

            if (prev == 0 && mask != 0) {
                presses.push_back({ GetTickCount(), mask });
                while (presses.size() > combo.size()) presses.pop_front();

                if (presses.size() == combo.size() &&
                    (DWORD)(presses.back().t - presses.front().t) <= kWindowMs) {
                    bool ok = true;
                    for (size_t i = 0; i < combo.size(); i++)
                        if (presses[i].m != combo[i]) { ok = false; break; }
                    if (ok) {
                        Log("combo recognised");
                        presses.clear();
                        InterlockedExchange(&g_unlock, 1);
                        EnterCriticalSection(&_cs);
                        if (_events) _events->CredentialsChanged(_ctx);
                        LeaveCriticalSection(&_cs);
                    }
                }
            }
            prev = mask;
        }
    }

    LONG _ref;
    CREDENTIAL_PROVIDER_USAGE_SCENARIO _cpus;
    ICredentialProviderEvents* _events;
    UINT_PTR _ctx;
    CRITICAL_SECTION _cs;
    HANDLE _thread, _stop;
};

IFACEMETHODIMP CCredential::SetSelected(BOOL* pbAutoLogon)
{
    *pbAutoLogon = InterlockedCompareExchange(&g_unlock, 0, 0) ? TRUE : FALSE;
    return S_OK;
}

IFACEMETHODIMP CCredential::GetSerialization(CREDENTIAL_PROVIDER_GET_SERIALIZATION_RESPONSE* pcpgsr,
                                             CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* pcpcs,
                                             PWSTR*, CREDENTIAL_PROVIDER_STATUS_ICON*)
{
    *pcpgsr = CPGSR_NO_CREDENTIAL_NOT_FINISHED;

    WORD mask;
    if (!InterlockedCompareExchange(&g_unlock, 0, 0) || !ReadPads(&mask)) return S_OK;

    Config cfg;
    if (!LoadConfig(cfg)) return S_OK;

    BYTE* pb = nullptr; DWORD cb = 0; ULONG pkg = 0;
    HRESULT hr = PackCredentials(cfg, _cpus, &pb, &cb);
    WipeConfig(cfg);
    if (SUCCEEDED(hr)) hr = NegotiatePackage(&pkg);
    if (FAILED(hr)) {
        Log("serialization failed hr=0x%08lx", (unsigned long)hr);
        if (pb) CoTaskMemFree(pb);
        InterlockedExchange(&g_unlock, 0);
        return S_OK;
    }

    pcpcs->ulAuthenticationPackage = pkg;
    pcpcs->clsidCredentialProvider = CLSID_MoonlightUnlock;
    pcpcs->cbSerialization = cb;
    pcpcs->rgbSerialization = pb;
    *pcpgsr = CPGSR_RETURN_CREDENTIAL_FINISHED;

    WriteFlag();
    InterlockedExchange(&g_unlock, 0);
    Log("unlock passed to Windows");
    return S_OK;
}

// ---------------------------------------------------------------- class factory + exports
class CFactory : public IClassFactory
{
public:
    CFactory() : _ref(1) {}
    virtual ~CFactory() {}
    IFACEMETHODIMP_(ULONG) AddRef() { return InterlockedIncrement(&_ref); }
    IFACEMETHODIMP_(ULONG) Release() { LONG r = InterlockedDecrement(&_ref); if (!r) delete this; return r; }
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv)
    {
        if (riid == IID_IUnknown || riid == IID_IClassFactory) {
            *ppv = static_cast<IClassFactory*>(this); AddRef(); return S_OK;
        }
        *ppv = nullptr; return E_NOINTERFACE;
    }
    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv)
    {
        if (outer) return CLASS_E_NOAGGREGATION;
        CProvider* p = new (std::nothrow) CProvider();
        if (!p) return E_OUTOFMEMORY;
        HRESULT hr = p->QueryInterface(riid, ppv);
        p->Release();
        return hr;
    }
    IFACEMETHODIMP LockServer(BOOL lock)
    {
        if (lock) InterlockedIncrement(&g_cRef); else InterlockedDecrement(&g_cRef);
        return S_OK;
    }
private:
    LONG _ref;
};

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv)
{
    if (rclsid != CLSID_MoonlightUnlock) return CLASS_E_CLASSNOTAVAILABLE;
    CFactory* f = new (std::nothrow) CFactory();
    if (!f) return E_OUTOFMEMORY;
    HRESULT hr = f->QueryInterface(riid, ppv);
    f->Release();
    return hr;
}

STDAPI DllCanUnloadNow() { return g_cRef == 0 ? S_OK : S_FALSE; }

BOOL APIENTRY DllMain(HMODULE h, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) { g_hinst = h; DisableThreadLibraryCalls(h); }
    return TRUE;
}
