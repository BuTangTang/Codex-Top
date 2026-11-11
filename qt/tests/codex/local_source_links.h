#pragma once
#include <QDir>
#include <QFile>
#include <filesystem>
#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif
namespace local_fixture {
// 使用真正的文件系统符号链接。Qt 在 Windows 的 QFile::link 创建 Shell 快捷方式。
inline bool symlink(const QString &path, const QString &dest, bool directory = false) {
#ifdef Q_OS_WIN
    const auto link = QDir::toNativeSeparators(path).toStdWString();
    const auto target = QDir::toNativeSeparators(dest).toStdWString();
    const DWORD flags = directory ? SYMBOLIC_LINK_FLAG_DIRECTORY : 0;
    if (CreateSymbolicLinkW(link.c_str(), target.c_str(), flags | 2))
        return true;
    return CreateSymbolicLinkW(link.c_str(), target.c_str(), flags);
#else
    Q_UNUSED(directory);
    std::error_code e;
    std::filesystem::create_symlink(QFile::encodeName(dest).constData(), QFile::encodeName(path).constData(), e);
    return !e;
#endif
}
// 删除链接自身，包括指向目录和自引用的链接。
inline bool unlinkFixture(const QString &path) {
    std::error_code error;
    return std::filesystem::remove(std::filesystem::path(path.toStdU16String()), error);
}
} // namespace local_fixture
