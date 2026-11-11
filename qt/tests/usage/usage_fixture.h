#pragma once
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QTest>
#include <QTimeZone>

namespace usage_fixture {
inline const auto now = QDateTime::fromSecsSinceEpoch(1800000000, QTimeZone::UTC);
/// 只在用例创建的临时文件设置合成 mtime，模拟原生用例的七日筛选。
inline void write(const QString &path, const QByteArray &data, const QDateTime &mtime = now, bool append = false) {
    QFile file(path);
    QVERIFY2(file.open(QIODevice::WriteOnly | (append ? QIODevice::Append : QIODevice::Truncate)),
             qPrintable(file.errorString()));
    QCOMPARE(file.write(data), data.size());
    QVERIFY(file.flush());
    QVERIFY(file.setFileTime(mtime, QFileDevice::FileModificationTime));
}
inline QByteArray record(const QJsonObject &row) { return QJsonDocument(row).toJson(QJsonDocument::Compact) + '\n'; }
} // namespace usage_fixture
