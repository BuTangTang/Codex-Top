#include "models/task_roots.h"
#include <algorithm>

namespace codextop {
QHash<QString, QString> resolveRootIDs(const QList<CodexTask> &tasks) {
    QHash<QString, std::optional<QString>> parents;
    for (const auto &task : tasks) {
        if (!parents.contains(task.id))
            parents.insert(task.id, task.parentID);
    }
    QHash<QString, QString> roots;
    for (const auto &task : tasks) {
        QString current = task.id;
        QStringList path;
        QHash<QString, qsizetype> positions;
        while (!roots.contains(current) && !positions.contains(current)) {
            positions.insert(current, path.size());
            path.append(current);
            const auto parent = parents.value(current);
            if (!parent || !parents.contains(*parent))
                break;
            current = *parent;
        }
        QString root = current;
        if (roots.contains(current))
            root = roots.value(current);
        else if (positions.contains(current) && path.last() != current)
            root = *std::min_element(path.cbegin() + positions.value(current), path.cend());
        // 已走过的路径共用同一个根，其他后代无需重复走完整条祖先链。
        for (const auto &id : path)
            roots.insert(id, root);
    }
    return roots;
}
} // namespace codextop
