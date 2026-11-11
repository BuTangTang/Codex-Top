#include "claude/claude_transcript_reducer.h"
#include <QTest>
using namespace codextop;
class ClaudeToolActivityTextTests : public QObject {
    Q_OBJECT
private slots:
    /// 原生 ToolActivityTextTests 的 Claude 用例，按工具名和思考段更新副标题。
    void testClaudeToolUseAndThinking() {
        ClaudeTranscriptReducer r;
        r.consume(R"({"type":"user","timestamp":"2027-01-15T08:00:00Z","message":{"role":"user","content":"go"}})");
        r.consume(R"({"type":"assistant","timestamp":"2027-01-15T08:00:01Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"secret"}}]}})");
        QCOMPARE(r.activity.detail,QStringLiteral("正在运行命令"));
        r.consume(R"({"type":"assistant","timestamp":"2027-01-15T08:00:02Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"secret"}]}})");
        QCOMPARE(r.activity.detail,QStringLiteral("正在思考"));
    }
};
QTEST_GUILESS_MAIN(ClaudeToolActivityTextTests)
#include "test_claude_tool_activity_text.moc"
