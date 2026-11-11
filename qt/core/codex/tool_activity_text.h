#pragma once
#include <QString>

namespace codextop::ToolActivityText {
/// 只按工具名选择面板副标题，不读取对话正文或工具参数。
QString detail(const QString &name);
}
