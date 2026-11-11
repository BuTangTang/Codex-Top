#pragma once
#include "codex/desktop_reply_receipt_source.h"
#include "codex/local_codex_source.h"

namespace codextop {
// 数据库/增量读取测试使用真实读取器，回执另有合成管道专项，永不连接用户的桌面进程。
class IsolatedCodexSource : public LocalCodexSource {
  public:
    explicit IsolatedCodexSource(const QString &root, const QString &cache = {})
        : LocalCodexSource(
              root, cache,
              std::make_shared<DesktopReplyReceiptSource>(root, DesktopReceiptLimits{.timeout = 0})) {}
};
} // namespace codextop
