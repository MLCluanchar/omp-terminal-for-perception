#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include <winsock2.h>
#include <windows.h>
#include <commdlg.h>
#include <cwctype>
#include <objidl.h>
#include <gdiplus.h>
#undef small
#include <filesystem>
#include <fstream>
#include <ws2tcpip.h>
#include <algorithm>
#include <atomic>
#include <cctype>
#include <iostream>
#include <sstream>
#include <map>
#include <mutex>
#include <string>
#include <sstream>
#include <thread>
#include <vector>
#include "json.hpp"
#include "grid.hpp"

using json = nlohmann::json;
constexpr int port = 17844;
static int columns = 100, rows = 30;
static TerminalGrid grid(columns, rows);
static std::mutex gridMutex, inputMutex;
static HANDLE inputWrite = nullptr, outputRead = nullptr, child = nullptr, job = nullptr;
static HPCON console;
namespace fs = std::filesystem;
static fs::path captureDirectory;
static std::atomic<ULONGLONG> capturePublished{0};
static std::atomic<bool> dialogOpen{false};
static std::thread terminalReader;

static bool writePipe(HANDLE pipe, const std::string& data) {
    size_t offset = 0;
    while (offset < data.size()) {
        DWORD written = 0;
        if (!WriteFile(pipe, data.data() + offset, static_cast<DWORD>(data.size() - offset), &written, nullptr) || !written)
            return false;
        offset += written;
    }
    return true;
}

static bool writeInput(const std::string& data) {
    std::lock_guard lock(inputMutex);
    return writePipe(inputWrite, data);
}

static std::atomic<ULONGLONG> keyboardLease{0};
static std::atomic<int> keyboardHookState{0};
static std::atomic<DWORD> keyboardInputThread{0};

static bool keyboardCaptured() {
    return keyboardHookState == 1 && keyboardLease.load() > GetTickCount64();
}

static std::string translateKey(const KBDLLHOOKSTRUCT& key, const BYTE* keys) {
    switch (key.vkCode) {
    case VK_ESCAPE: return "\x1b";
    case VK_RETURN: return "\r";
    case VK_BACK: return "\x7f";
    case VK_TAB: return keys[VK_SHIFT] & 128 ? "\x1b[Z" : "\t";
    case VK_UP: return "\x1b[A";
    case VK_DOWN: return "\x1b[B";
    case VK_RIGHT: return "\x1b[C";
    case VK_LEFT: return "\x1b[D";
    case VK_HOME: return "\x1b[H";
    case VK_END: return "\x1b[F";
    case VK_PRIOR: return "\x1b[5~";
    case VK_NEXT: return "\x1b[6~";
    case VK_DELETE: return "\x1b[3~";
    }
    if ((keys[VK_CONTROL] & 128) && key.vkCode >= 'A' && key.vkCode <= 'Z')
        return std::string(1, char(key.vkCode - 'A' + 1));

    wchar_t chars[8]{};
    DWORD foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
    int count = ToUnicodeEx(key.vkCode, key.scanCode, keys, chars, int(std::size(chars)), 4,
                            GetKeyboardLayout(foregroundThread));
    if (count <= 0) return {};
    char bytes[32]{};
    int size = WideCharToMultiByte(CP_UTF8, 0, chars, count, bytes, int(sizeof(bytes)), nullptr, nullptr);
    return size > 0 ? std::string(bytes, size) : std::string{};
}

static LRESULT CALLBACK ompKeyboardHook(int code, WPARAM message, LPARAM event) {
    static BYTE keys[256]{};
    static bool swallowed[256]{};
    if (code != HC_ACTION) return CallNextHookEx(nullptr, code, message, event);
    const auto& key = *reinterpret_cast<const KBDLLHOOKSTRUCT*>(event);
    const DWORD vk = key.vkCode;
    if (vk >= 256) return CallNextHookEx(nullptr, code, message, event);
    const bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
    if (vk == VK_CAPITAL && down && !(keys[vk] & 128)) keys[vk] ^= 1;
    keys[vk] = (keys[vk] & 1) | (down ? 128 : 0);
    keys[VK_SHIFT] = keys[VK_LSHIFT] | keys[VK_RSHIFT];
    keys[VK_CONTROL] = keys[VK_LCONTROL] | keys[VK_RCONTROL];
    keys[VK_MENU] = keys[VK_LMENU] | keys[VK_RMENU];
    if (!down && swallowed[vk]) { swallowed[vk] = false; return 1; }
    if (!down || !keyboardCaptured()) return CallNextHookEx(nullptr, code, message, event);
    if (vk == VK_F8 && (keys[VK_SHIFT] & 128)) {
        keyboardLease = 0;
        swallowed[vk] = true;
        return 1;
    }
    // Leave Windows switching and system shortcuts with the current foreground app.
    if (vk == VK_LWIN || vk == VK_RWIN || vk == VK_LMENU || vk == VK_RMENU ||
        (key.flags & LLKHF_ALTDOWN)) {
        keyboardLease = 0;
        return CallNextHookEx(nullptr, code, message, event);
    }
    auto bytes = translateKey(key, keys);
    if (!bytes.empty()) {
        auto* pending = new (std::nothrow) std::string(std::move(bytes));
        if (!pending || !PostThreadMessageW(keyboardInputThread, WM_APP + 1, 0,
                                             reinterpret_cast<LPARAM>(pending))) {
            delete pending;
            keyboardLease = 0;
            return CallNextHookEx(nullptr, code, message, event);
        }
    }
    swallowed[vk] = true;
    return 1;
}

static void enableKeyboardCapture() {
    static std::once_flag started;
    std::call_once(started, [] {
        std::thread([] {
            MSG message{};
            PeekMessageW(&message, nullptr, 0, 0, PM_NOREMOVE);
            keyboardInputThread = GetCurrentThreadId();
            while (GetMessageW(&message, nullptr, 0, 0) > 0) {
                if (message.message != WM_APP + 1) continue;
                std::unique_ptr<std::string> text(reinterpret_cast<std::string*>(message.lParam));
                if (*text == "\x03") {
                    // Escape is OMP's native stop key while a response is streaming.
                    std::lock_guard lock(gridMutex);
                    for (const auto& line : grid.lines()) {
                        if (line.find("Working") != std::string::npos) {
                            *text = "\x1b";
                            break;
                        }
                    }
                }
                if (!writeInput(*text)) keyboardLease = 0;
            }
        }).detach();
        std::thread([] {
            HHOOK hook = SetWindowsHookExW(WH_KEYBOARD_LL, ompKeyboardHook, GetModuleHandleW(nullptr), 0);
            keyboardHookState = hook ? 1 : -1;
            if (!hook) return;
            MSG message{};
            while (GetMessageW(&message, nullptr, 0, 0) > 0) DispatchMessageW(&message);
            UnhookWindowsHookEx(hook);
        }).detach();
    });
    for (int attempt = 0; attempt < 25 && (!keyboardInputThread || keyboardHookState == 0); ++attempt)
        Sleep(4);
    if (keyboardHookState != 1 || !keyboardInputThread) throw std::runtime_error("Keyboard hook unavailable");
    keyboardLease = GetTickCount64() + 1500;
}

// Windows may propagate a redirected parent's standard handles even when attaching
// the child to a pseudoconsole. Open fresh handles inside that console before
// starting the Bun shim, whose TUI tests GetConsoleMode on stdin.
static fs::path ompExecutable() {
    wchar_t profile[32768];
    DWORD len = GetEnvironmentVariableW(L"USERPROFILE", profile, 32768);
    if (!len || len >= 32768) return {};
    return fs::path(profile) / L".bun" / L"bin" / L"omp.exe";
}

static int runAttachedOMP() {
    const auto exe = ompExecutable();
    if (exe.empty()) return 1;
    std::wstring cmd = L"\"" + exe.wstring() + L"\"";
    wchar_t module[32768];
    DWORD moduleLength = GetModuleFileNameW(nullptr, module, 32768);
    if (moduleLength && moduleLength < 32768 &&
        GetEnvironmentVariableW(L"OMP_OVERLAY_CAPTURE_DIR", nullptr, 0)) {
        auto extension = fs::path(module).parent_path() / L"omp-capture-attachment.ts";
        if (fs::is_regular_file(extension)) cmd += L" --extension \"" + extension.wstring() + L"\"";
    }
    SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};
    HANDLE in=CreateFileW(L"CONIN$",GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,0,nullptr);
    HANDLE out=CreateFileW(L"CONOUT$",GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,0,nullptr);
    if(in==INVALID_HANDLE_VALUE || out==INVALID_HANDLE_VALUE) return 3;
    SetStdHandle(STD_INPUT_HANDLE,in); SetStdHandle(STD_OUTPUT_HANDLE,out); SetStdHandle(STD_ERROR_HANDLE,out);
    STARTUPINFOW si{}; si.cb=sizeof(si);
    si.dwFlags=STARTF_USESTDHANDLES; si.hStdInput=in;si.hStdOutput=out;si.hStdError=out;
    PROCESS_INFORMATION pi{};
    if(!CreateProcessW(exe.c_str(),cmd.data(),nullptr,nullptr,TRUE,0,nullptr,nullptr,&si,&pi)) return 4;
    CloseHandle(pi.hThread); WaitForSingleObject(pi.hProcess,INFINITE);
    DWORD code=1; GetExitCodeProcess(pi.hProcess,&code); CloseHandle(pi.hProcess);
    CloseHandle(in); CloseHandle(out); return int(code);
}
static bool launchOMP(const char*& failure) {
    wchar_t module[32768];
    DWORD len=GetModuleFileNameW(nullptr,module,32768);
    if(!len || len>=32768) return false;
    std::wstring exe(module, len);
    exe.resize(exe.find_last_of(L'\\') + 1);
    exe += L"omp-terminal-worker.exe";
    std::error_code ignored;
    if (!fs::is_regular_file(exe, ignored)) {
        failure = "OMP host worker is missing";
        return false;
    }
    std::wstring cmd=L"\""+exe+L"\" --attached-omp";
    HANDLE inputRead, outputWrite;
    if (!CreatePipe(&inputRead,&inputWrite,nullptr,0) || !CreatePipe(&outputRead,&outputWrite,nullptr,0)) return false;
    HRESULT hr = CreatePseudoConsole({SHORT(columns),SHORT(rows)},inputRead,outputWrite,0,&console);
    CloseHandle(inputRead);
    CloseHandle(outputWrite);
    if (FAILED(hr)) { std::cerr << "CreatePseudoConsole HRESULT: " << std::hex << hr << "\n"; return false; }
    SIZE_T bytes=0;
    InitializeProcThreadAttributeList(nullptr,1,0,&bytes);
    std::vector<unsigned char> memory(bytes);
    auto attrs = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(memory.data());
    if (!InitializeProcThreadAttributeList(attrs,1,0,&bytes) ||
        !UpdateProcThreadAttribute(attrs,0,PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,console,sizeof(console),nullptr,nullptr)) return false;
    STARTUPINFOEXW si{};
    si.StartupInfo.cb=sizeof(si); si.lpAttributeList=attrs;
    PROCESS_INFORMATION pi{};
    job=CreateJobObjectW(nullptr,nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION lim{};
    lim.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job || !SetInformationJobObject(job,JobObjectExtendedLimitInformation,&lim,sizeof(lim))) return false;
    BOOL ok=CreateProcessW(exe.c_str(),cmd.data(),nullptr,nullptr,FALSE,
                           EXTENDED_STARTUPINFO_PRESENT|CREATE_SUSPENDED,nullptr,nullptr,&si.StartupInfo,&pi);
    DWORD err = GetLastError();
    DeleteProcThreadAttributeList(attrs);
    if (!ok) { SetLastError(err); return false; }
    if (!AssignProcessToJobObject(job,pi.hProcess) || ResumeThread(pi.hThread)==DWORD(-1)) {
        TerminateProcess(pi.hProcess,1); return false;
    }
    child=pi.hProcess; CloseHandle(pi.hThread);
    terminalReader = std::thread([] {
        char buffer[32768]; DWORD n;
        while (ReadFile(outputRead,buffer,sizeof(buffer),&n,nullptr) && n) {
            std::string reply;
            {
                std::lock_guard lock(gridMutex);
                reply=grid.feed(std::string(buffer,n));
            }
            if (!reply.empty()) writeInput(reply);
        }
    });
    return true;
}

static bool terminalRunning() {
    return child && WaitForSingleObject(child, 0) == WAIT_TIMEOUT;
}

static json overlayLayout;

static void loadOverlayLayout() {
    std::ifstream file("omp-overlay-layout.json", std::ios::binary);
    std::string contents(4096, '\0');
    file.read(contents.data(), std::streamsize(contents.size()));
    contents.resize(size_t(file.gcount()));
    auto layout = json::parse(contents, nullptr, false);
    if (!layout.is_object()) return;
    try {
        columns = std::clamp(layout.value("cols", columns), 36, 160);
        rows = std::clamp(layout.value("rows", rows), 10, 60);
        grid.resize(columns, rows);
        overlayLayout = std::move(layout);
    } catch (const json::exception&) {}
}

static void saveOverlayLayout(const json& data) {
    json layout = {{"x",std::clamp(data.at("x").get<int>(),0,32767)},
        {"y",std::clamp(data.at("y").get<int>(),0,32767)},
        {"ballX",std::clamp(data.at("ballX").get<int>(),0,32767)},
        {"ballY",std::clamp(data.at("ballY").get<int>(),0,32767)},
        {"minimized",data.at("minimized").get<int>() != 0 ? 1 : 0},
        {"keyboardHook",data.value("keyboardHook",overlayLayout.is_object() ? overlayLayout.value("keyboardHook",1) : 1) != 0 ? 1 : 0},
        {"cols",columns},{"rows",rows}};
    if (layout == overlayLayout) return;
    std::ofstream file("omp-overlay-layout.part", std::ios::binary | std::ios::trunc);
    file << layout.dump();
    file.close();
    if (!file || !MoveFileExW(L"omp-overlay-layout.part", L"omp-overlay-layout.json",
                              MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        throw std::runtime_error("Cannot save overlay layout");
    overlayLayout = std::move(layout);
}

static int visibleOffset(const json& request) {
    const int requested = std::clamp(request.value("scroll", 0), 0, grid.historySize());
    if (requested == 0) return 0;
    const uint64_t serial = grid.historySerial();
    const auto anchor = request.value("anchor", serial);
    if (anchor >= serial) return requested;
    return int(std::min<uint64_t>(grid.historySize(), uint64_t(requested) + (serial - anchor)));
}

static bool copyText(const std::string& text) {
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), int(text.size()), nullptr, 0);
    if (count <= 0) return false;
    HGLOBAL data = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, size_t(count + 1) * sizeof(wchar_t));
    if (!data) return false;
    auto* words = static_cast<wchar_t*>(GlobalLock(data));
    if (!words) { GlobalFree(data); return false; }
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), int(text.size()), words, count);
    GlobalUnlock(data);
    HWND owner = CreateWindowExW(0,L"STATIC",L"",0,0,0,0,0,HWND_MESSAGE,nullptr,nullptr,nullptr);
    bool copied = false;
    if (owner && OpenClipboard(owner)) {
        copied = EmptyClipboard() && SetClipboardData(CF_UNICODETEXT, data);
        CloseClipboard();
    }
    if (owner) DestroyWindow(owner);
    if (!copied) GlobalFree(data);
    return copied;
}

static std::string clipboardText() {
    if (!OpenClipboard(nullptr)) throw std::runtime_error("Clipboard is busy");
    std::wstring text;
    if (HANDLE data = GetClipboardData(CF_UNICODETEXT)) {
        if (auto value = static_cast<const wchar_t*>(GlobalLock(data))) {
            const auto capacity = GlobalSize(data) / sizeof(wchar_t);
            for (size_t i = 0; i < capacity && i < 32000 && value[i]; ++i)
                if (value[i] >= 32 || value[i] == L'\n' || value[i] == L'\t')
                    text += value[i];
            GlobalUnlock(data);
        }
    }
    CloseClipboard();
    int size = WideCharToMultiByte(CP_UTF8, 0, text.data(), int(text.size()), nullptr, 0, nullptr, nullptr);
    if (!size) throw std::runtime_error("Clipboard has no text");
    std::string output(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), int(text.size()), output.data(), size, nullptr, nullptr);
    return output;
}

static std::atomic<int> snipStatus{0};
static std::atomic<const char*> attachmentDiagnostic{""};

static void failAttachment(const char* reason) {
    attachmentDiagnostic = reason;
    snipStatus = 4;
}

static std::string encodePng(HBITMAP bitmap) {
    ULONG_PTR token = 0;
    Gdiplus::GdiplusStartupInput options;
    if (Gdiplus::GdiplusStartup(&token, &options, nullptr) != Gdiplus::Ok) return {};
    std::string bytes;
    IStream* stream = nullptr;
    if (SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) {
        Gdiplus::Bitmap image(bitmap, nullptr);
        const CLSID pngEncoder{0x557cf406,0x1a04,0x11d3,{0x9a,0x73,0,0,0xf8,0x1e,0xf3,0x2e}};
        STATSTG info{};
        HGLOBAL memory = nullptr;
        if (image.Save(stream, &pngEncoder, nullptr) == Gdiplus::Ok &&
            SUCCEEDED(stream->Stat(&info, STATFLAG_NONAME)) &&
            info.cbSize.QuadPart > 0 && info.cbSize.QuadPart <= 16 * 1024 * 1024 &&
            SUCCEEDED(GetHGlobalFromStream(stream, &memory))) {
            if (auto* data = static_cast<const char*>(GlobalLock(memory))) {
                bytes.assign(data, size_t(info.cbSize.QuadPart));
                GlobalUnlock(memory);
            }
        }
        stream->Release();
    }
    Gdiplus::GdiplusShutdown(token);
    return bytes;
}

static std::string capturePng(HDC source, const RECT& box) {
    const int width = box.right - box.left, height = box.bottom - box.top;
    HDC dc = CreateCompatibleDC(source);
    HBITMAP bitmap = CreateCompatibleBitmap(source, width, height);
    auto old = dc && bitmap ? SelectObject(dc, bitmap) : nullptr;
    bool captured = old && BitBlt(dc, 0, 0, width, height, source, box.left, box.top, SRCCOPY | CAPTUREBLT);
    if (old) SelectObject(dc, old);
    if (dc) DeleteDC(dc);
    std::string png = captured ? encodePng(bitmap) : std::string{};
    if (bitmap) DeleteObject(bitmap);
    return png;
}

static void beginSnip(RECT box) {
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    const int left = GetSystemMetrics(SM_XVIRTUALSCREEN);
    const int top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    RECT desktop{left, top, left + GetSystemMetrics(SM_CXVIRTUALSCREEN),
                 top + GetSystemMetrics(SM_CYVIRTUALSCREEN)};
    if (!IntersectRect(&box, &box, &desktop) || box.right-box.left < 2 || box.bottom-box.top < 2 ||
        int64_t(box.right-box.left) * (box.bottom-box.top) > 24 * 1024 * 1024)
        throw std::runtime_error("Invalid capture region");
    if (captureDirectory.empty()) throw std::runtime_error("Attachment channel is unavailable");
    if (snipStatus == 1 || snipStatus == 5 || snipStatus == 6) throw std::runtime_error("Attachment pending");
    auto directory = captureDirectory;
    std::error_code ignored;
    fs::remove(directory / L"receipt", ignored);
    snipStatus = 1;
    std::thread([box, directory] {
        SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        Sleep(150);
        HDC screen = GetDC(nullptr);
        const auto bytes = screen ? capturePng(screen, box) : std::string{};
        if (screen) ReleaseDC(nullptr, screen);
        if (bytes.empty()) { failAttachment("Could not capture screen region"); return; }
        const auto staging = directory / L"capture.part";
        std::ofstream file(staging, std::ios::binary | std::ios::trunc);
        file.write(bytes.data(), std::streamsize(bytes.size()));
        file.close();
        const auto incoming = directory / L"capture.png";
        if (!file || !MoveFileExW(staging.c_str(), incoming.c_str(), MOVEFILE_REPLACE_EXISTING)) {
            DeleteFileW(staging.c_str());
            failAttachment("Could not save screenshot");
            return;
        }
        capturePublished = GetTickCount64();
        snipStatus = 5;
    }).detach();
}

static void chooseAttachment() {
    if (captureDirectory.empty()) throw std::runtime_error("Attachment channel is unavailable");
    if (snipStatus == 1 || snipStatus == 5 || snipStatus == 6 || dialogOpen.exchange(true))
        throw std::runtime_error("An attachment or dialog is already pending");
    auto directory = captureDirectory;
    snipStatus = 6;
    std::thread([directory] {
        wchar_t selected[32768]{};
        OPENFILENAMEW picker{};
        picker.lStructSize = sizeof(picker);
        picker.lpstrFile = selected;
        picker.nMaxFile = DWORD(std::size(selected));
        picker.lpstrTitle = L"Attach a file to OMP";
        picker.lpstrFilter = L"All files (*.*)\0*.*\0Images\0*.png;*.jpg;*.jpeg;*.webp;*.gif\0";
        picker.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER | OFN_DONTADDTORECENT;
        bool chosen = GetOpenFileNameW(&picker);
        if (!chosen) {
            if (CommDlgExtendedError()) failAttachment("Windows file picker failed");
            else snipStatus = 3;
            dialogOpen = false;
            return;
        }
        try {
            fs::path input(selected);
            auto ext = input.extension().wstring();
            for (auto& ch : ext) ch = wchar_t(std::towlower(ch));
            if (ext == L".jpeg") ext = L".jpg";
            const auto size = fs::file_size(input);
            const bool preview = size && size <= 16 * 1024 * 1024 &&
                (ext == L".png" || ext == L".jpg" || ext == L".webp" || ext == L".gif");
            const auto staging = directory / L"capture.part";
            const auto incoming = directory / (preview ? L"capture" + ext : L"capture.reference");
            std::error_code ignored;
            fs::remove(directory / L"receipt", ignored);
            if (preview) {
                fs::copy_file(input, staging, fs::copy_options::overwrite_existing);
            } else {
                std::ofstream file(staging, std::ios::binary | std::ios::trunc);
                const auto path = input.generic_u8string();
                file.write(reinterpret_cast<const char*>(path.data()), path.size());
                file.close();
                if (!file) throw std::runtime_error("Cannot queue file reference");
            }
            if (!MoveFileExW(staging.c_str(), incoming.c_str(), MOVEFILE_REPLACE_EXISTING))
                throw std::runtime_error("Cannot queue image");
            capturePublished = GetTickCount64();
            snipStatus = 5;
        } catch (...) {
            DeleteFileW((directory / L"capture.part").c_str());
            failAttachment("Could not read or stage selected file");
        }
        dialogOpen = false;
    }).detach();
}

static void updateCaptureStatus() {
    if (snipStatus != 5) return;
    const auto receipt = captureDirectory / L"receipt";
    std::ifstream file(receipt);
    std::string result;
    if (file >> result) {
        file.close();
        DeleteFileW(receipt.c_str());
        if (result == "ok") snipStatus = 2;
        else failAttachment("OMP could not add the file to its draft");
    } else if (GetTickCount64() - capturePublished.load() > 4500) {
        for (const auto* name : {L"capture.png", L"capture.jpg", L"capture.webp", L"capture.gif", L"capture.reference"})
            DeleteFileW((captureDirectory / name).c_str());
        failAttachment("OMP did not confirm the attachment");
    }
}

static void prepareCaptureDirectory() {
    wchar_t temp[32768];
    wchar_t folder[MAX_PATH];
    const DWORD length = GetTempPathW(DWORD(std::size(temp)), temp);
    if (!length || length >= std::size(temp) || !GetTempFileNameW(temp, L"omp", 0, folder)) return;
    if (!DeleteFileW(folder) || !CreateDirectoryW(folder, nullptr)) return;
    captureDirectory = folder;
    SetEnvironmentVariableW(L"OMP_OVERLAY_CAPTURE_DIR", folder);
}

static void resetTerminal() {
    if (job) { CloseHandle(job); job = nullptr; }
    if (console) { ClosePseudoConsole(console); console = nullptr; }
    if (terminalReader.joinable()) terminalReader.join();
    for (HANDLE* handle : {&child, &inputWrite, &outputRead}) {
        if (*handle) { CloseHandle(*handle); *handle = nullptr; }
    }
    std::lock_guard lock(gridMutex);
    grid.feed("\x1b" "c");
    grid.clearHistory();
}

static LRESULT CALLBACK composeProc(HWND window,UINT msg,WPARAM wp,LPARAM lp) {
    if (msg==WM_CREATE) {
        HWND edit=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",L"",WS_VISIBLE|WS_CHILD|WS_TABSTOP|ES_AUTOHSCROLL,
            12,15,430,32,window,(HMENU)10,nullptr,nullptr);
        SendMessageW(edit,EM_SETLIMITTEXT,4096,0);
        CreateWindowW(L"BUTTON",L"Insert",WS_VISIBLE|WS_CHILD|WS_TABSTOP|BS_DEFPUSHBUTTON,
            250,66,90,28,window,(HMENU)IDOK,nullptr,nullptr);
        CreateWindowW(L"BUTTON",L"Cancel",WS_VISIBLE|WS_CHILD|WS_TABSTOP,
            352,66,90,28,window,(HMENU)IDCANCEL,nullptr,nullptr);
        SetFocus(edit); return 0;
    }
    if (msg==WM_COMMAND && (LOWORD(wp)==IDOK || LOWORD(wp)==IDCANCEL)) {
        if (LOWORD(wp)==IDOK) {
            wchar_t content[4097]{};
            int size=GetDlgItemTextW(window,10,content,4097);
            int count=WideCharToMultiByte(CP_UTF8,0,content,size,nullptr,0,nullptr,nullptr);
            if (count>0) {
                std::string text(count,'\0');
                WideCharToMultiByte(CP_UTF8,0,content,size,text.data(),count,nullptr,nullptr);
                writeInput(text);
            }
        }
        DestroyWindow(window); return 0;
    }
    if (msg==WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(window,msg,wp,lp);
}

static void compose() {
    if (dialogOpen.exchange(true)) return;
    std::thread([]{
        WNDCLASSW wc{}; wc.hInstance=GetModuleHandleW(nullptr); wc.lpfnWndProc=composeProc;
        wc.lpszClassName=L"EnmaOmpCompose"; wc.hbrBackground=(HBRUSH)(COLOR_BTNFACE+1);
        wc.hCursor=LoadCursorW(nullptr,IDC_ARROW); RegisterClassW(&wc);
        HWND win=CreateWindowExW(WS_EX_TOPMOST,wc.lpszClassName,L"OMP Unicode input",
            WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_VISIBLE,CW_USEDEFAULT,CW_USEDEFAULT,480,145,
            nullptr,nullptr,wc.hInstance,nullptr);
        if (win) {
            SetForegroundWindow(win); SetFocus(GetDlgItem(win,10));
            MSG msg{};
            while (GetMessageW(&msg,nullptr,0,0)>0) {
                if (!IsDialogMessageW(win,&msg)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
            }
        }
        dialogOpen=false;
    }).detach();
}

static json route(const std::string& path,const json& body) {
    if (path=="/layout") {
        if (body.contains("x")) saveOverlayLayout(body);
        return overlayLayout.is_object() ? overlayLayout : json::object();
    }
    if (path=="/copy") {
        std::string selection;
        {
            std::lock_guard lock(gridMutex);
            selection = grid.selectedText(visibleOffset(body), body.at("first").get<int>(), body.at("last").get<int>());
        }
        if (!copyText(selection)) throw std::runtime_error("Cannot copy selection");
        return {{"ok",1}};
    }
    if (path=="/keyboard") {
        if (body.value("enabled",false) && terminalRunning()) enableKeyboardCapture();
        else keyboardLease = 0;
        return {{"captured",int(keyboardCaptured())}};
    }
    if (path=="/status") return {{"ready",1},{"alive",int(terminalRunning())},{"snip",snipStatus.load()}};
    if (path=="/screen") {
        if (body.value("keyboard",false) && keyboardCaptured()) keyboardLease = GetTickCount64() + 1500;
        static uint64_t previousLaunch = 0;
        static std::string startupDiagnostic;
        if (!terminalRunning() && !dialogOpen && (!previousLaunch || GetTickCount64() - previousLaunch >= 3000)) {
            previousLaunch = GetTickCount64();
            const char* failure = "Could not start the OMP terminal";
            std::error_code ignored;
            if (!fs::is_regular_file(ompExecutable(), ignored))
                failure = "omp.exe missing from .bun/bin";
            else {
                resetTerminal();
                if (launchOMP(failure)) failure = "";
            }
            startupDiagnostic = failure;
        }
        if (!terminalRunning()) {
            DWORD code = 0;
            if (startupDiagnostic.empty() && child && GetExitCodeProcess(child, &code)) {
                startupDiagnostic = "OMP exited (code " + std::to_string(code) + "); retrying";
                resetTerminal();
            }
            return {{"alive",0},{"diagnostic",startupDiagnostic.empty() ? "Waiting for OMP to start" : startupDiagnostic}};
        }
        updateCaptureStatus();
        std::lock_guard lock(gridMutex);
        const int offset = visibleOffset(body);
        return {{"cols",columns},{"rows",rows},{"lines",grid.lines(offset)},{"paint",grid.paint(offset)},
            {"scroll",offset},{"history",grid.historySize()},{"historySerial",grid.historySerial()},
            {"cursorX",grid.cursorX()},{"cursorY",grid.cursorY()},{"cursorVisible",int(offset == 0 && grid.cursorVisible())},
            {"alive",1},{"snip",snipStatus.load()},{"keyboard",int(keyboardCaptured())},
            {"attachmentDiagnostic",snipStatus == 4 ? attachmentDiagnostic.load() : ""}};
    }
    if (!terminalRunning()) throw std::runtime_error("OMP has exited");
    if (path=="/resize") {
        const int newCols = body.at("cols").get<int>();
        const int newRows = body.at("rows").get<int>();
        if (newCols < 36 || newCols > 160 || newRows < 10 || newRows > 60)
            throw std::runtime_error("Invalid terminal size");
        if (newCols != columns || newRows != rows) {
            {
                std::lock_guard lock(gridMutex);
                grid.resize(newCols, newRows);
            }
            if (FAILED(ResizePseudoConsole(console, {SHORT(newCols),SHORT(newRows)}))) {
                std::lock_guard lock(gridMutex);
                grid.resize(columns, rows);
                throw std::runtime_error("Cannot resize terminal");
            }
            columns = newCols;
            rows = newRows;
        }
        return {{"ok",1}};
    }
    if (path=="/paste") {
        if (!writeInput("\x1b[200~" + clipboardText() + "\x1b[201~"))
            throw std::runtime_error("Cannot paste into terminal");
        return {{"ok",1}};
    }
    if (path=="/cursor") {
        POINT pos{};
        if (!GetPhysicalCursorPos(&pos)) throw std::runtime_error("Cannot read cursor position");
        return {{"x",pos.x},{"y",pos.y}};
    }
    if (path=="/screenshot") {
        beginSnip({body.at("left").get<LONG>(), body.at("top").get<LONG>(),
                   body.at("right").get<LONG>(), body.at("bottom").get<LONG>()});
        return {{"ok",1}};
    }
    if (path=="/attach") { chooseAttachment(); return {{"ok",1}}; }
    if (path=="/compose") { compose(); return {{"ok",1}}; }
    if (path!="/input" || !body.contains("text") || !body["text"].is_string()) throw std::runtime_error("Invalid input");
    auto input=body["text"].get<std::string>();
    if (input=="\x03") {
        // OMP 18.10 displays the Escape-key hint above its live status bar.
        // Its idle editor still needs a literal Ctrl+C for normal editing.
        std::lock_guard lock(gridMutex);
        auto lines=grid.lines();
        for (size_t i=0; i+1<lines.size(); ++i) {
            auto first=lines[i].find_first_not_of(' ');
            if (first!=std::string::npos && lines[i].substr(first)==u8"⎋ Working…" &&
                lines[i+1].find(" > ")!=std::string::npos) {
                input="\x1b";
                break;
            }
        }
    }
    if (!writeInput(input)) throw std::runtime_error("Cannot write to terminal");
    return {{"ok",1}};
}

static std::string lower(std::string s) {
    for(char& c:s) c=char(std::tolower(static_cast<unsigned char>(c)));
    return s;
}
static std::string trim(const std::string& s) {
    auto a=s.find_first_not_of(" \t\r"), b=s.find_last_not_of(" \t\r");
    return a==std::string::npos ? "" : s.substr(a,b-a+1);
}
static void handle(SOCKET sock) {
    DWORD timeout=900;
    setsockopt(sock,SOL_SOCKET,SO_RCVTIMEO,reinterpret_cast<const char*>(&timeout),sizeof(timeout));
    setsockopt(sock,SOL_SOCKET,SO_SNDTIMEO,reinterpret_cast<const char*>(&timeout),sizeof(timeout));
    json response;
    bool ok=false;
    try {
        std::string req; char buf[4096];
        auto receive=[&] { int n=recv(sock,buf,sizeof(buf),0); if(n<=0) throw std::runtime_error("Incomplete request"); req.append(buf,n); };
        size_t pos;
        while ((pos=req.find("\r\n\r\n"))==std::string::npos) {
            if(req.size()>8192) throw std::runtime_error("Headers too large"); receive();
        }
        std::istringstream stream(req.substr(0,pos)); std::string line, method, path, version;
        std::getline(stream,line); std::istringstream requestLine(line); requestLine>>method>>path>>version;
        std::map<std::string,std::string> headers;
        while(std::getline(stream,line)) {
            auto separator=line.find(':'); if(separator==std::string::npos) throw std::runtime_error("Invalid header");
            auto name=lower(trim(line.substr(0,separator))); if(headers.count(name)) throw std::runtime_error("Repeated header");
            headers[name]=trim(line.substr(separator+1));
        }
        if(method!="POST" || headers["host"]!="127.0.0.1:17844" || headers.count("origin") || headers.count("transfer-encoding")
            || lower(trim(headers["content-type"].substr(0,headers["content-type"].find(';'))))!="application/json")
            throw std::runtime_error("Local JSON POST required");
        std::string length=headers["content-length"];
        if(length.empty() || length.size()>5 || length.find_first_not_of("0123456789")!=std::string::npos)
            throw std::runtime_error("Invalid size");
        size_t size=std::stoul(length); if(size>32768) throw std::runtime_error("Request too large");
        pos+=4; while(req.size()-pos<size) receive();
        auto payload=json::parse(req.substr(pos,size)); if(!payload.is_object()) throw std::runtime_error("Expected JSON object");
        response=route(path,payload); ok=true;
    } catch(...) { response={{"ok",0},{"error","Bad request or terminal unavailable"}}; }
    auto data=response.dump(-1,' ',false,json::error_handler_t::replace);
    std::string out="HTTP/1.1 "+std::string(ok?"200 OK":"400 Bad Request")+"\r\nConnection: close\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: "+std::to_string(data.size())+"\r\n\r\n"+data;
    for(size_t i=0;i<out.size();) {int n=send(sock,out.data()+i,int(out.size()-i),0); if(n<=0) break; i+=n;}
    closesocket(sock);
}

int main(int argc,char** argv) {
    if(argc==2 && std::string(argv[1])=="--attached-omp") return runAttachedOMP();
    if (argc==2 && std::string(argv[1])=="--background") {
        wchar_t module[32768];
        const DWORD len = GetModuleFileNameW(nullptr, module, 32768);
        if (!len || len >= 32768) return 2;
        std::wstring directory(module, len);
        directory.resize(directory.find_last_of(L'\\'));
        if (!SetCurrentDirectoryW(directory.c_str())) return 2;
    }
    WSADATA wsa{}; if(WSAStartup(MAKEWORD(2,2),&wsa)) return 1;
    SOCKET server=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
    BOOL exclusive=TRUE;
    setsockopt(server,SOL_SOCKET,SO_EXCLUSIVEADDRUSE,reinterpret_cast<const char*>(&exclusive),sizeof(exclusive));
    sockaddr_in addr{}; addr.sin_family=AF_INET; addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK); addr.sin_port=htons(port);
    if(bind(server,reinterpret_cast<sockaddr*>(&addr),sizeof(addr)) || listen(server,8)) {
        std::cerr<<"Cannot listen on 127.0.0.1:17844\n"; return 1;
    }
    prepareCaptureDirectory();
    loadOverlayLayout();
    std::cout<<"OMP terminal listening on 127.0.0.1:17844\n"<<std::flush;
    for(;;) {
        SOCKET connection=accept(server,nullptr,nullptr);
        if(connection==INVALID_SOCKET) break;
        DWORD timeout=1500;
        setsockopt(connection,SOL_SOCKET,SO_RCVTIMEO,reinterpret_cast<const char*>(&timeout),sizeof(timeout));
        setsockopt(connection,SOL_SOCKET,SO_SNDTIMEO,reinterpret_cast<const char*>(&timeout),sizeof(timeout));
        handle(connection);
    }
    resetTerminal();
    return 0;
}
