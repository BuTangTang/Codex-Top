#include "account_usage_protocol.h"
#include <QTimeZone>
#include <cmath>
#include <limits>

namespace codextop {

QString errorDescription(AccountUsageClientError error) {
    switch (error) {
    case AccountUsageClientError::CliUnavailable: return QStringLiteral("未找到可用的 Codex CLI，暂时无法读取账户额度。");
    case AccountUsageClientError::TimedOut: return QStringLiteral("读取账户额度超时，请稍后刷新。");
    case AccountUsageClientError::Unavailable: return QStringLiteral("暂时无法读取账户额度，请检查 Codex 登录与网络后重试。");
    case AccountUsageClientError::InvalidResponse: return QStringLiteral("当前 Codex 额度格式不可用，请更新 Codex 或稍后重试。");
    }
    Q_UNREACHABLE();
}

namespace AccountUsageProtocol {

const QByteArray &initialize() {
    static const QByteArray data = R"({"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex_top","title":"Codex Top","version":"0.1.0"}}})" "\n";
    return data;
}

const QByteArray &read() {
    static const QByteArray data = R"({"method":"initialized"})" "\n" R"({"id":2,"method":"account/rateLimits/read"})" "\n";
    return data;
}

namespace {
/// JSON 布尔值和数字必须区分，任何非有限数也不能作为额度。
std::optional<double> number(const QJsonValue &value) {
    if (!value.isDouble() || !std::isfinite(value.toDouble())) return std::nullopt;
    return value.toDouble();
}
}

QuotaSnapshot decodeResult(const QJsonObject &result, const QDateTime &now) {
    QJsonObject bucket;
    const auto buckets = result.value("rateLimitsByLimitId");
    if (buckets.isObject()) {
        const auto codex = buckets.toObject().value("codex");
        if (!codex.isObject()) throw AccountUsageClientError::Unavailable;
        bucket = codex.toObject();
    } else if (result.value("rateLimits").isObject()) {
        bucket = result.value("rateLimits").toObject();
    } else {
        throw AccountUsageClientError::InvalidResponse;
    }
    const auto id = bucket.value("limitId");
    if (id.isString() && id.toString() != "codex") throw AccountUsageClientError::Unavailable;
    QuotaSnapshot snapshot{now, {}, QuotaOrigin::Account};
    for (const auto &key : {"primary", "secondary"}) {
        const auto window = bucket.value(key).toObject();
        const auto used = number(window.value("usedPercent"));
        const auto duration = number(window.value("windowDurationMins"));
        using Minutes = decltype(QuotaWindow::minutes);
        // Swift Int(exactly:) 对截断、小数和超界值都返回 nil。
        const double upperBound = std::ldexp(1.0, std::numeric_limits<Minutes>::digits);
        if (!used || *used < 0 || !duration || *duration <= 0 || *duration >= upperBound
                || *duration != std::trunc(*duration)) continue;
        std::optional<QDateTime> resetsAt;
        if (auto reset = number(window.value("resetsAt")); reset && *reset >= 0 && *reset <= 253402300799.0)
            resetsAt = QDateTime::fromMSecsSinceEpoch(qint64(std::floor(*reset * 1000.0)), QTimeZone::UTC);
        snapshot.windows.append({static_cast<Minutes>(*duration), *used, resetsAt});
    }
    if (snapshot.windows.isEmpty()) throw AccountUsageClientError::Unavailable;
    return snapshot;
}

}
}
