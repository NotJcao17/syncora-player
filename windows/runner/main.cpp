#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Create a named mutex to detect running instances atomically
  HANDLE hMutex = ::CreateMutex(NULL, TRUE, L"SyncoraPlayer_SingleInstance_Mutex");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    // Another instance is running! Find its HWND window handle
    HWND existing_hwnd = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", NULL);
    if (existing_hwnd != NULL) {
      if (::IsIconic(existing_hwnd)) {
        ::ShowWindow(existing_hwnd, SW_RESTORE);
      } else {
        ::ShowWindow(existing_hwnd, SW_SHOW);
      }
      ::SetForegroundWindow(existing_hwnd);

      // Forward ONLY the deep link URI to existing window via WM_COPYDATA
      std::vector<std::string> command_line_arguments = GetCommandLineArguments();
      std::string uri_arg = "";
      for (const auto& arg : command_line_arguments) {
        if (arg.rfind("syncoraplayer://", 0) == 0 || arg.find("://") != std::string::npos) {
          uri_arg = arg;
          break;
        }
      }
      if (uri_arg.empty() && command_line_arguments.size() > 1) {
        uri_arg = command_line_arguments[1];
      }

      if (!uri_arg.empty()) {
        COPYDATASTRUCT cds;
        cds.dwData = 0; // app_links expects dwData = 0
        cds.cbData = static_cast<DWORD>(uri_arg.length() + 1);
        cds.lpData = const_cast<char*>(uri_arg.c_str());
        ::SendMessage(existing_hwnd, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&cds));
      }
    }
    if (hMutex) ::CloseHandle(hMutex);
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Syncora Player", origin, size)) {
    if (hMutex) ::CloseHandle(hMutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (hMutex) ::CloseHandle(hMutex);
  return EXIT_SUCCESS;
}
