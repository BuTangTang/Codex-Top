#include "rollout_test_support.h"
#include "codex/tool_activity_text.h"
using namespace rolloutFixture;

class ToolActivityTextTests : public QObject {
    Q_OBJECT
private slots:
    /// 常用工具、中间件及未知工具分别显示既有文案。
    void testMapping() {
        QCOMPARE(ToolActivityText::detail("shell"), QStringLiteral("正在运行命令"));
        QCOMPARE(ToolActivityText::detail("Bash"), QStringLiteral("正在运行命令"));
        QCOMPARE(ToolActivityText::detail("apply_patch"), QStringLiteral("正在编辑文件"));
        QCOMPARE(ToolActivityText::detail("Edit"), QStringLiteral("正在编辑文件"));
        QCOMPARE(ToolActivityText::detail("Grep"), QStringLiteral("正在查看文件"));
        QCOMPARE(ToolActivityText::detail("mcp__github__create_issue"), QStringLiteral("正在调用工具"));
        QCOMPARE(ToolActivityText::detail("something_new"), QStringLiteral("正在执行任务"));
    }
    /// 面板只显示工具类型和思考状态，正文和参数不会进入副标题。
    void testCodexFunctionCallUsesToolName() {
        RolloutReducer reducer;
        reducer.consume(startTurn("t"));
        reducer.consume(response("function_call", 1, {{"name","apply_patch"},{"call_id","c1"},{"arguments","secret"}}));
        QCOMPARE(reducer.activity.detail, QStringLiteral("正在编辑文件"));
        reducer.consume(recordEvent("agent_reasoning", 2, {{"text","secret"}}));
        QCOMPARE(reducer.activity.detail, QStringLiteral("正在思考"));
    }
};
QTEST_GUILESS_MAIN(ToolActivityTextTests)
#include "test_tool_activity_text.moc"
