#pragma once

class QWindow;

// 平台层：各平台各写一份，其余代码共用。
namespace platform {

// 程序不出现在程序坞／任务栏（只有悬浮球和菜单栏／托盘入口）。
void prepareApplication();

// 悬浮小窗：不抢焦点、置顶、所有桌面都显示、不进切换器。点它、拖它时，正在用的程序保持输入状态。
void configureFloatingWindow(QWindow *window);

} // namespace platform
