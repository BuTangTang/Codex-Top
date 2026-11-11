#include "../platform/platform.h"

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QScreen>

using namespace Qt::StringLiterals;

// REQ-004 M0 技术验证：只有一个悬浮球。点一下在“3 个在跑”和“没有在跑”之间切换，用来量动画和空闲两种占用。
// 测试参数：--idle 以“没有在跑”启动；--screen N 放到第 N 块屏（从 0 数）右上方。
int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);
    platform::prepareApplication();
    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("CodexTop", "Main");
    const QStringList args = app.arguments();
    for (QObject *object : engine.rootObjects()) {
        auto *window = qobject_cast<QQuickWindow *>(object);
        if (!window) continue;
        if (args.contains(u"--idle"_s)) {
            if (auto *canvas = window->findChild<QObject *>(u"canvas"_s)) canvas->setProperty("running", 0);
        }
        const qsizetype at = args.indexOf(u"--screen"_s);
        if (at >= 0 && at + 1 < args.size()) {
            const auto screens = QGuiApplication::screens();
            const int index = args[at + 1].toInt();
            if (index >= 0 && index < screens.size()) {
                const QRect area = screens[index]->availableGeometry();
                window->setScreen(screens[index]);
                window->setPosition(area.right() - window->width() - 120, area.top() + 200);
            }
        }
        platform::configureFloatingWindow(window);
    }
    return app.exec();
}
