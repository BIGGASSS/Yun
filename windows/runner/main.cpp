#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(0, 0);
  Win32Window::Size size(1280, 720);
  const HMONITOR primary_monitor =
      ::MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  RECT work_area{};
  if (::GetMonitorInfo(primary_monitor, &monitor_info)) {
    work_area = monitor_info.rcWork;
  } else {
    ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0);
  }
  const int work_width = work_area.right - work_area.left;
  const int work_height = work_area.bottom - work_area.top;
  if (work_width > 0 && work_height > 0) {
    const double scale_factor =
        FlutterDesktopGetDpiForMonitor(primary_monitor) / 96.0;
    size.width = static_cast<unsigned int>(
        std::max(1.0, std::min(1280.0, work_width * 0.9 / scale_factor)));
    size.height = static_cast<unsigned int>(
        std::max(1.0, std::min(720.0, work_height * 0.9 / scale_factor)));
    origin.x = work_area.left +
               (work_width - static_cast<int>(size.width * scale_factor)) / 2;
    origin.y = work_area.top +
               (work_height - static_cast<int>(size.height * scale_factor)) / 2;
  }
  // Bootstrap on the primary monitor so Dart's logical bounds use its DPI.
  // Dart defers the first frame while configuring; the existing frame callback
  // remains responsible for showing the window.
  if (!window.Create(L"\u97F5", origin, size)) {
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
