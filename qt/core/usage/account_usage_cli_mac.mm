#import <AppKit/AppKit.h>
#include <QString>

namespace codextop {

/// 按官方 bundle ID 查找当前注册的应用，支持移动及更名的 Codex.app。
QString registeredCodexApplication() {
    @autoreleasepool {
        NSURL *app = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.openai.codex"];
        return app ? QString::fromNSString(app.path) : QString{};
    }
}

}
