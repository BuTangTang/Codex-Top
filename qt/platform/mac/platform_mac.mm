#include "../platform.h"

#import <AppKit/AppKit.h>
#include <QWindow>

namespace platform {

void prepareApplication() {
    // 和原生版一样是“附属程序”：没有程序坞图标，点悬浮球不会把整个程序切到前台。
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

void configureFloatingWindow(QWindow *window) {
    auto *view = reinterpret_cast<NSView *>(window->winId());
    NSWindow *native = view.window;
    if (!native) return;
    // Qt 对工具窗口创建的是 NSPanel；加上“不激活”样式，点它不会把焦点从别的程序抢过来。
    if ([native isKindOfClass:[NSPanel class]]) {
        native.styleMask |= NSWindowStyleMaskNonactivatingPanel;
        static_cast<NSPanel *>(native).becomesKeyOnlyIfNeeded = YES;
        static_cast<NSPanel *>(native).floatingPanel = YES;
    }
    native.hidesOnDeactivate = NO;
    native.level = NSStatusWindowLevel;
    native.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary
        | NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorStationary;
    native.hasShadow = NO;
}

} // namespace platform
