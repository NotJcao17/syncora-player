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

  // Check if another instance of Syncora Player is already running
  HWND existing_hwnd = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Syncora Player");
  if (existing_hwnd != NULL) {
    // Restore and bring existing window to front
    if (::IsIconic(existing_hwnd)) {
      ::ShowWindow(existing_hwnd, SW_RESTORE);
    } else {
      ::ShowWindow(existing_hwnd, SW_SHOW);
    }
    ::SetForegroundWindow(existing_hwnd);

    // Forward command line arguments to existing window via WM_COPYDATA
    std::vector<std::string> command_line_arguments = GetCommandLineArguments();
    if (!command_line_arguments.empty()) {
      std::string cmd = "";
      for (size_t i = 0; i < command_line_arguments.size(); ++i) {
        if (i > 0) cmd += " ";
        cmd += command_line_arguments[i];
      }
      COPYDATASTRUCT cds;
      cds.dwData = 1;
      cds.cbData = static_cast<DWORD>(cmd.length() + 1);
      cds.lpData = const_cast<char*>(cmd.c_str());
      ::SendMessage(existing_hwnd, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&cds));
    }
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
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
