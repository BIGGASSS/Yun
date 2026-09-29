#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  close_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "yun/desktop_close",
          &flutter::StandardMethodCodec::GetInstance());
  close_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "hasTrayIcon") {
          // Coupled to pinned tray_manager 0.5.3's _ApplyIcon/GetMainWindow:
          // the icon uses the root Yun HWND, uID 1, and no GUID. Recheck this
          // identity when upgrading the plugin; Explorer's presence alone is
          // not evidence that our icon was successfully registered.
          NOTIFYICONIDENTIFIER identifier{};
          identifier.cbSize = sizeof(identifier);
          identifier.hWnd = GetHandle();
          identifier.uID = 1;
          RECT rect{};
          const HRESULT status = Shell_NotifyIconGetRect(&identifier, &rect);
          const bool available = SUCCEEDED(status) &&
                                 rect.right > rect.left &&
                                 rect.bottom > rect.top;
          result->Success(flutter::EncodableValue(available));
          return;
        }
        if (call.method_name() != "setEnabled") {
          result->NotImplemented();
          return;
        }
        const auto* enabled = call.arguments()
                                  ? std::get_if<bool>(call.arguments())
                                  : nullptr;
        if (!enabled) {
          result->Error("invalid_argument", "setEnabled requires a boolean");
          return;
        }
        intercept_close_ = *enabled;
        result->Success();
      });

  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  intercept_close_ = false;
  if (close_channel_) {
    close_channel_->SetMethodCallHandler(nullptr);
    close_channel_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_CLOSE && intercept_close_ && close_channel_) {
    close_channel_->InvokeMethod("onClose", nullptr);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
