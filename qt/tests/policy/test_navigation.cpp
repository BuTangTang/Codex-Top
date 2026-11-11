#include "models/models.h"
#include <QTest>
using namespace codextop;
class NavigationTests : public QObject {
    Q_OBJECT
    static CodexTask task(const QString &id) {
        CodexTask task;
        task.id = id;
        task.title = "Synthetic";
        task.project = "Fixture";
        task.createdAt = task.updatedAt = QDateTime::currentDateTimeUtc();
        task.rolloutPath = "/fixture/rollout.jsonl";
        return task;
    }
  private slots:
    void testThreadLinkPreservesTheSelectedTaskID() {
        const QString id = "00000000-0000-4000-8000-000000000003";
        auto link = task(id).deepLink();
        QVERIFY(link);
        QCOMPARE(link->toString(), "codex://threads/" + id);
    }
    void testInvalidIDsCannotChangeDestinationOrAddQueryParameters() {
        for (const auto &id : {"", "not-an-id", "../settings/usage", "00000000-0000-4000-8000-000000000003?host=other",
                               "https://example.com"})
            QVERIFY(!task(id).deepLink());
    }
};
QTEST_APPLESS_MAIN(NavigationTests)
#include "test_navigation.moc"
