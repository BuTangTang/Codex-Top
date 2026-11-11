#include "policy_fixture.h"
#include <algorithm>

using namespace policy_test;
namespace {
using RootMap = QHash<QString, QString>;
CodexTask member(const QString &id, std::optional<QString> parent = std::nullopt, const QString &title = QStringLiteral("合成任务")) {
    CodexTask value;
    value.id = id;
    value.parentID = std::move(parent);
    value.title = title;
    value.project = QStringLiteral("合成项目");
    value.createdAt = at(1);
    value.updatedAt = at(2);
    value.rolloutPath = "/synthetic/rollout.jsonl";
    return value;
}

QList<CodexTask> reversed(QList<CodexTask> tasks) {
    std::reverse(tasks.begin(), tasks.end());
    return tasks;
}

QString key(const QString &id) { return id.normalized(QString::NormalizationForm_C); }

// 独立对照：从每个编号重新沿其首个父关系查找，不用被测实现的路径缓存或活动索引。
RootMap legacyRootIDs(const QList<CodexTask> &tasks) {
    QHash<QString, std::optional<QString>> parents;
    for (const auto &t : tasks) {
        if (!parents.contains(key(t.id)))
            parents.insert(key(t.id), t.parentID);
    }
    RootMap result;
    for (auto it = parents.cbegin(); it != parents.cend(); ++it) {
        QString current = it.key();
        QStringList path;
        while (!path.contains(current)) {
            path.append(current);
            const auto parent = parents.value(current);
            if (!parent || !parents.contains(key(*parent)))
                break;
            current = key(*parent);
        }
        auto root = current;
        if (current != path.last()) {
            auto cycle = path.mid(path.indexOf(current));
            std::sort(cycle.begin(), cycle.end(), [](const QString &a, const QString &b) { return a.toUtf8() < b.toUtf8(); });
            root = cycle.first();
        }
        result.insert(it.key(), root);
    }
    return result;
}

void compareMapping(const QList<CodexTask> &tasks, const RootMap &expected) {
    const TaskGraph graph(tasks);
    QCOMPARE(resolveRootIDs(tasks), expected);
    QCOMPARE(graph.rootIDs, expected);
    QList<CodexTask> roots;
    QHash<QString, QList<CodexTask>> children;
    for (const auto &t : tasks) {
        const auto root = expected.value(key(t.id));
        if (root == key(t.id))
            roots.append(t);
        else
            children[root].append(t);
    }
    QCOMPARE(graph.roots, roots);
    QCOMPARE(graph.children, children);
    for (const auto &root : roots)
        compareSelection(graph, root, children.value(key(root.id)));
}
void compareLegacy(const QList<CodexTask> &tasks) {
    compareMapping(tasks, legacyRootIDs(tasks));
}
}

class TaskGraphRootMappingTests : public QObject {
    Q_OBJECT
private slots:
    void testRootsOrphansAndCyclesKeepTheirOriginalResolution() {
        const QList tasks = {member("plain"), member("orphan", "missing"), member("orphan-child", "orphan"),
            member("self", "self"), member("cycle-b", "cycle-a"), member("cycle-a", "cycle-b"), member("descendant", "cycle-b")};
        const RootMap expected = {{"plain","plain"},{"orphan","orphan"},{"orphan-child","orphan"},{"self","self"},
            {"cycle-a","cycle-a"},{"cycle-b","cycle-a"},{"descendant","cycle-a"}};
        for (const auto &ordering : {tasks, reversed(tasks), tasks.mid(3) + tasks.first(3)})
            compareMapping(ordering, expected);
    }
    void testFirstDuplicateControlsParentageWithoutDroppingMembers() {
        const auto first = member("duplicate", "a", "第一项");
        const auto second = member("duplicate", "b", "第二项");
        const auto a = member("a"), b = member("b"), child = member("child", "duplicate");
        compareMapping({first, child, a, second, b}, {{"duplicate","a"},{"child","a"},{"a","a"},{"b","b"}});
        compareMapping({second, child, b, first, a}, {{"duplicate","b"},{"child","b"},{"a","a"},{"b","b"}});
        const auto standalone = member("duplicate", std::nullopt, "独立根");
        compareMapping({standalone, first, a, child}, {{"duplicate","duplicate"},{"a","a"},{"child","duplicate"}});
    }
    void testRebuildingReflectsChangedAndMissingParents() {
        const auto a = member("a"), b = member("b");
        auto child = member("child", "a");
        const TaskGraph original({child, a, b});
        compareMapping({child, a, b}, {{"child","a"},{"a","a"},{"b","b"}});
        child.parentID = "b";
        compareMapping({child, a, b}, {{"child","b"},{"a","a"},{"b","b"}});
        compareMapping({child, a}, {{"child","child"},{"a","a"}});
        child.parentID.reset();
        compareMapping({child, a, b}, {{"child","child"},{"a","a"},{"b","b"}});
        QCOMPARE(original.rootIDs.value("child"), "a");
    }
    void testEmptyAndDeepChainsResolveInBothInputOrders() {
        compareMapping({}, {});
        QList<CodexTask> tasks;
        RootMap expected;
        for (int i = 0; i < 120; ++i) {
            const QString id = QString("node-%1").arg(i);
            tasks.append(member(id, i ? std::optional(tasks.last().id) : std::nullopt));
            expected.insert(id, "node-0");
        }
        compareMapping(tasks, expected);
        compareMapping(reversed(tasks), expected);
    }
    void testLegacyOracleKeepsAllMembersOrderAndActivityAcrossMixedBoundaries() {
        const QList input = {member("child-a", "a"), member("duplicate"), member("b"), member("duplicate","b","后来的父项"),
            member("descendant","duplicate"), member("cycle-b","cycle-a"), member("a"), member("cycle-a","cycle-b"),
            member("second-a","a"), member("orphan","missing"), member("orphan-child","orphan"), member("self","self")};
        for (int offset = 0; offset < 7; ++offset) {
            auto tasks = input;
            for (qsizetype i = 0; i < tasks.size(); ++i) {
                auto &a = tasks[i].activity;
                a.phase = phases[(i + offset) % 7];
                a.detail = QStringLiteral("合成活动-%1").arg(i);
                a.startedAt = at(i);
                a.turnID = QString("turn-%1").arg(i);
            }
            for (qsizetype split = 0; split < tasks.size(); ++split) {
                const auto ordered = tasks.mid(split) + tasks.first(split);
                compareLegacy(ordered);
                compareLegacy(reversed(ordered));
            }
        }
    }
    void testLegacyOracleMatchesDeterministicDuplicateAndUnicodeInputs() {
        const QStringList names = {"", "a", "b", "重复", "é", QStringLiteral("e\u0301"), "环-a", "环-b", "leaf", "root"};
        quint64 state = 0x91;
        const auto next = [&](qsizetype count) {
            state = state * Q_UINT64_C(6364136223846793005) + 1;
            return qsizetype((state >> 32) % quint64(count));
        };
        compareLegacy({});
        for (int snapshot = 0; snapshot < 48; ++snapshot) {
            QList<CodexTask> tasks;
            for (int i = 0; i < 64; ++i) {
                const auto id = names.at(next(names.size()));
                const auto p = next(names.size() + 2);
                std::optional<QString> parent;
                if (p != names.size())
                    parent = p > names.size() ? QString("missing") : names.at(p);
                auto t = member(id, parent, QStringLiteral("合成快照-%1-%2").arg(snapshot).arg(i));
                t.activity.phase = phases[next(7)];
                t.activity.detail = QStringLiteral("合成详情-%1").arg(i);
                t.activity.startedAt = at(i);
                t.activity.turnID = QString("turn-%1-%2").arg(snapshot).arg(i);
                tasks.append(t);
            }
            compareLegacy(tasks);
            compareLegacy(reversed(tasks));
        }
    }
};
QTEST_APPLESS_MAIN(TaskGraphRootMappingTests)
#include "test_task_graph_root_mapping.moc"
