#pragma once
#include <QString>
#include <optional>

namespace codextop::ClaudeHookInstaller {
enum class Failure { InvalidJSON, ChangedWhileEditing, WriteFailed };
/// 生成 Claude Code 实际执行的指令。小程序缺失时直接退出成功。
QString command(const QString &helper);
/// 缺少文件返回 false，损坏的设置返回无值。
std::optional<bool> isInstalled(const QString &settings, const QString &helper);
/// 在原字节序列插入本应用的通知钩子；失败抛出 Failure。
void install(const QString &settings, const QString &helper, const QString &backups);
/// 撤销本应用的条目；保留用户的其他设置和原有布局。
void remove(const QString &settings, const QString &helper, const QString &backups);
} // namespace codextop::ClaudeHookInstaller
