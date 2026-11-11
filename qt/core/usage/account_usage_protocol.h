#pragma once

#include "models/models.h"
#include <QByteArray>
#include <QJsonObject>

namespace codextop {

enum class AccountUsageClientError { CliUnavailable, TimedOut, Unavailable, InvalidResponse };

/// 固定的公开提示。后端错误文字、认证字段及通知正文不离开协议边界。
QString errorDescription(AccountUsageClientError error);

/// 取消独立于服务端失败，不写入限频结果缓存。
struct AccountUsageCancelled {};

namespace AccountUsageProtocol {
/// 第一帧初始化请求，包含换行分隔符。
const QByteArray &initialize();
/// 收到成功初始化后发送 initialized 及 account/rateLimits/read。
const QByteArray &read();
/// 优先择取 codex 配额桶，只保留占比、窗口时长、重置时间及观察时间。
QuotaSnapshot decodeResult(const QJsonObject &result, const QDateTime &now);
}

}
