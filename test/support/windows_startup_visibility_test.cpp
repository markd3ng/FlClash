#include <windows.h>

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

void Require(bool condition, const char* message) {
  if (!condition) {
    std::cerr << message << " (Win32 error " << GetLastError() << ")\n";
    std::exit(EXIT_FAILURE);
  }
}

class WindowManager {
 public:
  explicit WindowManager(HWND window) : window_(window) {}
  HWND GetMainWindow() { return window_; }
  void Hide();

 private:
  HWND window_;
};

#include "window_manager_hide.inc"

void CheckChild(bool patched) {
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  GetStartupInfoW(&startup);
  Require((startup.dwFlags & STARTF_USESHOWWINDOW) != 0 &&
              startup.wShowWindow == SW_SHOWNORMAL,
          "Missing launcher show command");

  WNDCLASSW window_class{};
  window_class.lpfnWndProc = DefWindowProcW;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = L"FlClashStartupVisibilityFixture";
  Require(RegisterClassW(&window_class) != 0, "RegisterClass failed");
  HWND window = CreateWindowExW(
      0, window_class.lpszClassName, L"FlClash startup fixture",
      WS_OVERLAPPEDWINDOW, 0, 0, 100, 100, nullptr, nullptr,
      window_class.hInstance, nullptr);
  Require(window != nullptr, "CreateWindow failed");
  Require(!IsWindowVisible(window), "Window must start hidden");

  if (patched) {
    WindowManager manager(window);
    manager.Hide();
    manager.Hide();
    Require(!IsWindowVisible(window), "Silent launch became visible");
    ShowWindow(window, SW_SHOW);
    Require(IsWindowVisible(window), "Manual opening must still show the window");
    manager.Hide();
    Require(!IsWindowVisible(window), "Closing must still hide a visible window");
  } else {
    ShowWindow(window, SW_HIDE);
    Require(IsWindowVisible(window),
            "Control did not reproduce STARTUPINFO overriding SW_HIDE");
  }
  DestroyWindow(window);
  UnregisterClassW(window_class.lpszClassName, window_class.hInstance);
}

void RunChild(const std::wstring& executable, const wchar_t* mode) {
  std::wstring command = L"\"" + executable + L"\" " + mode;
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESHOWWINDOW;
  startup.wShowWindow = SW_SHOWNORMAL;
  PROCESS_INFORMATION process{};
  Require(CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr,
                         FALSE, 0, nullptr, nullptr, &startup, &process),
          "CreateProcess failed");
  CloseHandle(process.hThread);
  const DWORD wait = WaitForSingleObject(process.hProcess, 10000);
  if (wait != WAIT_OBJECT_0) {
    TerminateProcess(process.hProcess, EXIT_FAILURE);
    WaitForSingleObject(process.hProcess, 5000);
    CloseHandle(process.hProcess);
    Require(false, "Startup fixture timed out");
  }
  DWORD exit_code = EXIT_FAILURE;
  const bool read_exit_code = GetExitCodeProcess(process.hProcess, &exit_code);
  CloseHandle(process.hProcess);
  Require(read_exit_code && exit_code == EXIT_SUCCESS, "Startup fixture failed");
}

int main(int argument_count, char** arguments) {
  if (argument_count == 2) {
    const std::string mode = arguments[1];
    Require(mode == "--patched" || mode == "--control", "Unknown test mode");
    CheckChild(mode == "--patched");
    return EXIT_SUCCESS;
  }
  Require(argument_count == 1, "Unexpected fixture arguments");
  std::vector<wchar_t> path(32768);
  const DWORD length = GetModuleFileNameW(nullptr, path.data(), path.size());
  Require(length > 0 && length < path.size(), "GetModuleFileName failed");
  const std::wstring executable(path.data(), length);
  RunChild(executable, L"--control");
  RunChild(executable, L"--patched");
  return EXIT_SUCCESS;
}
