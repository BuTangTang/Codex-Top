#include "../platform.h"

#include <QWindow>
#include <windows.h>

namespace platform {

void prepareApplication() {}

void configureFloatingWindow(QWindow *window) {
    // 不激活 + 工具窗口：点它不抢焦点，也不出现在任务栏和 Alt+Tab 里。
    auto hwnd = reinterpret_cast<HWND>(window->winId());
    LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
    SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

} // namespace platform
