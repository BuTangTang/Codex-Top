#pragma once
#include "codex/local_codex_source.h"
#include <QtTest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QSqlError>
#include <QSqlRecord>
#include <QTemporaryDir>
#include <QDir>
#include <QSaveFile>
#include <QUuid>
#include <QTimeZone>
#include <stdexcept>

namespace local_fixture {
using namespace codextop;
// 所有测试均在独立临时目录创建库，路径直接绑定不拼进 SQL。
inline const QString schema = "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,created_at "
                              "INTEGER,updated_at INTEGER,archived INTEGER)";
inline const QDateTime now = QDateTime::fromSecsSinceEpoch(1800000000, QTimeZone::UTC);
inline QByteArray event(QString type, QDateTime at = now, QJsonObject extra = {{"turn_id", "synthetic-turn"}},
                        QString kind = "event_msg") {
    extra["type"] = type;
    return QJsonDocument(QJsonObject{{"type", kind}, {"timestamp", at.toString(Qt::ISODate)}, {"payload", extra}})
               .toJson(QJsonDocument::Compact) +
           '\n';
}
inline void write(const QString &path, const QByteArray &bytes, bool append = false) {
    if (!QDir().mkpath(QFileInfo(path).absolutePath()))
        throw std::runtime_error("cannot create fixture directory");
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | (append ? QIODevice::Append : QIODevice::Truncate)) ||
        f.write(bytes) != bytes.size())
        throw std::runtime_error("cannot write synthetic fixture");
}
inline QByteArray readFile(const QString &path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        throw std::runtime_error("cannot read synthetic fixture");
    return f.readAll();
}
inline void replaceFile(const QString &path, const QByteArray &bytes) {
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly) || f.write(bytes) != bytes.size() || !f.commit())
        throw std::runtime_error("cannot replace synthetic file");
}
struct Fixture {
    QTemporaryDir temp;
    QString base, root, outside, dbName;
    QSqlDatabase db;
    explicit Fixture(bool createSchema = true) {
        if (!temp.isValid())
            throw std::runtime_error("cannot create test directory");
        base = QFileInfo(temp.path()).canonicalFilePath();
        root = base + "/root";
        outside = base + "/outside";
        QDir().mkpath(root);
        QDir().mkpath(outside);
        dbName = QUuid::createUuid().toString();
        db = QSqlDatabase::addDatabase("QSQLITE", dbName);
        db.setDatabaseName(root + "/state_5.sqlite");
        if (!db.open())
            throw std::runtime_error(db.lastError().text().toStdString());
        if (createSchema)
            sql(schema);
    }
    ~Fixture() {
        db.close();
        db = QSqlDatabase{};
        QSqlDatabase::removeDatabase(dbName);
    }
    QString path(const QString &name) const {
        return root + '/' + name;
    }
    void sql(const QString &query, const QVariantList &values = {}) {
        QSqlQuery q(db);
        if (!q.prepare(query))
            throw std::runtime_error(q.lastError().text().toStdString());
        for (const auto &v : values)
            q.addBindValue(v);
        if (!q.exec())
            throw std::runtime_error(q.lastError().text().toStdString());
    }
    QList<QVariantList> select(const QString &query) {
        QSqlQuery q(db);
        if (!q.exec(query))
            throw std::runtime_error(q.lastError().text().toStdString());
        QList<QVariantList> rows;
        while (q.next()) {
            QVariantList cols;
            for (int i = 0; i < q.record().count(); ++i)
                cols << q.value(i);
            rows << cols;
        }
        return rows;
    }
    void add(const QString &id, const QString &file, const QString &title = "合成任务",
             const QString &cwd = "/synthetic", int updated = 2) {
        sql("INSERT INTO threads VALUES(?,?,?,?,1,?,0)", {id, title, cwd, file, updated});
    }
};
inline const CodexTask &task(const SourceSnapshot &s, const QString &id) {
    for (const auto &t : s.tasks)
        if (t.id == id)
            return t;
    throw std::runtime_error("missing fixture task");
}
} // namespace local_fixture
