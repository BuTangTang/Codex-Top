package com.butang.codextop;

import android.app.Instrumentation;
import android.app.Activity;
import android.content.Intent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import android.os.Bundle;
import java.util.Objects;
import org.json.JSONObject;

/** 在独立测试 APK 中验证 Android JSON、Keystore 和真实 HTTP 协议。 */
public class ContractTest extends Instrumentation {
    /** 使用平台 Instrumentation 启动，测试不依赖旧 android.test 运行库。 */
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }

    /** 执行六个明确的设备契约用例，以退出结果记录通过数量。 */
    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            testFixtureLoginSnapshotAndRevocation();
            testSessionEncryptionAndClear();
            testMalformedSnapshotRejected();
            testNativeNavigation();
            testChatScreenAndRoute();
            testRelayConversation();
            result.putString("stream", "\n通过 6 项设备契约与界面测试\n"); finish(-1, result);
        } catch (Throwable error) {
            result.putString("stream", "\n失败：" + error.getClass().getSimpleName() + " " + error.getMessage() + "\n"); finish(1, result);
        }
    }

    /** 断言值相等，不向输出泄露账号或会话内容。 */
    private void assertEquals(Object expected, Object actual) { if (!Objects.equals(expected, actual)) fail("值不匹配"); }
    /** 断言不成立，适用于密文中不应出现明文的检查。 */
    private void assertFalse(boolean condition) { if (condition) fail("条件不应成立"); }
    /** 缺少可靠开始时间和已退出会话必须保持空值。 */
    private void assertNull(Object value) { if (value != null) fail("应为空值"); }
    /** 中止当前测试并由运行入口统一生成简洁错误结果。 */
    private void fail(String message) { throw new AssertionError(message); }

    /** 启动真正的 Activity 并验证精简列表、详情与设置入口，捕获只编译无法发现的首帧崩溃。 */
    private void testNativeNavigation() {
        Activity activity = startActivitySync(new Intent(getTargetContext(), MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        waitForIdleSync();
        runOnMainSync(() -> {
            View content = activity.findViewById(android.R.id.content);
            View demo = findText(content, "先体验示例");
            if (demo == null) fail("登录页未显示");
            demo.performClick();
            if (findText(activity.findViewById(android.R.id.content), "合成示例") == null) fail("示例标识缺失");
            View screen = activity.findViewById(android.R.id.content);
            if (findText(screen, "运行中") != null || findText(screen, "我的") != null || findText(screen, "设备") != null) fail("多余导航仍存在");
            View title = findText(screen, "登录页面调整");
            if (title == null || findText(screen, "设置页面调整") == null) fail("合成通知列表不完整");
            View item = (View) title.getParent();
            while (item != null && !item.isClickable()) item = item.getParent() instanceof View ? (View) item.getParent() : null;
            if (item == null) fail("通知行不可点击");
            findDescription(activity.findViewById(android.R.id.content), "设置").performClick();
            if (findText(activity.findViewById(android.R.id.content), "发送测试通知") == null) fail("设置页缺少测试入口");
            clickText(activity, "已连接电脑");
            View devices = activity.findViewById(android.R.id.content);
            if (findText(devices, "Mac mini") == null || findText(devices, "Windows PC") == null || findText(devices, "离线") == null) fail("多电脑状态缺失");
            findDescription(devices, "返回").performClick();
            clickText(activity, "通知设置");
            if (findText(activity.findViewById(android.R.id.content), "示例不可开启") == null) fail("合成模式错误允许后台提醒");
            findDescription(activity.findViewById(android.R.id.content), "返回").performClick();
            clickText(activity, "云端连接");
            if (findText(activity.findViewById(android.R.id.content), "合成数据，无真实服务器") == null) fail("示例冒充真实连接");
            findDescription(activity.findViewById(android.R.id.content), "返回").performClick();
            findDescription(activity.findViewById(android.R.id.content), "返回").performClick();
            if (findText(activity.findViewById(android.R.id.content), "登录页面调整") == null) fail("设置返回路径错误");
            activity.finish();
        });
    }

    /** 直接启动通知所用对话页，示例身份和固定来源可见且不会发送真实消息。 */
    private void testChatScreenAndRoute() {
        Intent intent = ChatActivity.intent(getTargetContext(), null, "mac-demo", "demo-0", true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        Activity activity = startActivitySync(intent); waitForIdleSync();
        runOnMainSync(() -> {
            View screen = activity.findViewById(android.R.id.content);
            if (findText(screen, "MacBook Pro · 合成示例") == null || findText(screen, "合成示例 · 不向电脑发送消息") == null) fail("对话来源标识缺失");
            View send = findText(screen, "发送");
            if (send == null || send.isEnabled()) fail("示例错误允许发送");
            activity.finish();
        });
        SessionStore.Session first = new SessionStore.Session("https://example.com", "token-a", "example");
        SessionStore.Session second = new SessionStore.Session("https://example.com", "token-b", "example");
        assertFalse(ChatActivity.intent(getTargetContext(), first, "mac", "same", false).filterEquals(ChatActivity.intent(getTargetContext(), second, "mac", "same", false)));
        assertFalse(ChatActivity.intent(getTargetContext(), first, "mac", "same", false).filterEquals(ChatActivity.intent(getTargetContext(), first, "pc", "same", false)));
    }

    /** 真实 HTTP 手机消息与合成电脑回复闭环，重试保持同 ID 且历史只出现一次。 */
    private void testRelayConversation() throws Exception {
        MobileApi api = new MobileApi();
        SessionStore.Session session = api.login("http://127.0.0.1:18766", "mobile-test", "fixture-only-password");
        try {
            ConversationRoute route = new ConversationRoute(ConversationRoute.scope(session.server(), session.token()), "relay-mac", "chat-example");
            String id = java.util.UUID.randomUUID().toString();
            api.send(session, route, id, "合成手机消息"); api.send(session, route, id, "合成手机消息");
            long deadline = android.os.SystemClock.elapsedRealtime() + 8000;
            boolean received = false;
            while (android.os.SystemClock.elapsedRealtime() < deadline) {
                var history = api.history(session, route, null);
                long count = history.messages().stream().filter(item -> item.id().equals(id)).count();
                assertEquals(1L, count);
                if (history.messages().stream().anyMatch(item -> item.id().equals(id) && item.state().equals("codex_received"))
                    && history.messages().stream().anyMatch(item -> item.role().equals("assistant") && item.text().equals("合成回复：已收到手机消息"))) { received = true; break; }
                android.os.SystemClock.sleep(200);
            }
            if (!received) fail("合成电脑回复未返回");
        } finally { api.logout(session); }
    }

    /** 点击文字所属的可操作行，验证整行入口而非依赖控件实现类型。 */
    private void clickText(Activity activity, String label) {
        View item = findText(activity.findViewById(android.R.id.content), label);
        while (item != null && !item.isClickable()) item = item.getParent() instanceof View ? (View) item.getParent() : null;
        if (item == null) fail("设置入口不可点击");
        item.performClick();
    }

    /** 按可见文字查找本应用原生控件，不使用屏幕坐标或其他应用信息。 */
    private View findText(View root, String text) {
        if (root instanceof TextView && ((TextView) root).getText().toString().equals(text)) return root;
        if (root instanceof ViewGroup) for (int index = 0; index < ((ViewGroup) root).getChildCount(); index++) {
            View match = findText(((ViewGroup) root).getChildAt(index), text);
            if (match != null) return match;
        }
        return null;
    }
    /** 通过无障碍名称查找图标按钮，确保图标入口也能被读屏识别。 */
    private View findDescription(View root, String label) {
        if (label.contentEquals(root.getContentDescription() == null ? "" : root.getContentDescription())) return root;
        if (root instanceof ViewGroup) for (int index = 0; index < ((ViewGroup) root).getChildCount(); index++) {
            View found = findDescription(((ViewGroup) root).getChildAt(index), label);
            if (found != null) return found;
        }
        return null;
    }

    /** 实际登录、获取合成快照并撤销；fixture 只监听经 adb reverse 的本机端口。 */
    public void testFixtureLoginSnapshotAndRevocation() throws Exception {
        MobileApi api = new MobileApi();
        try { api.login("http://127.0.0.1:18765", "mobile-test", "incorrect"); fail("错误密码被接受"); }
        catch (MobileApi.ApiException error) { assertEquals(401, error.status); }
        var session = api.login("http://127.0.0.1:18765", "mobile-test", "fixture-only-password");
        var snapshot = api.snapshot(session);
        assertEquals(2, snapshot.devices().size()); assertEquals(4, snapshot.tasks().size());
        assertNull(snapshot.tasks().get(1).startedAt());
        api.logout(session);
        try { api.snapshot(session); fail("旧会话仍有效"); }
        catch (MobileApi.ApiException error) { assertEquals(401, error.status); }
    }

    /** 密文可以还原本服务会话，退出后不再留存凭据。 */
    public void testSessionEncryptionAndClear() throws Exception {
        SessionStore store = new SessionStore(getTargetContext());
        var session = new SessionStore.Session("https://example.com", "synthetic-token-for-keystore-test", "合成账号");
        try {
            store.save(session); assertEquals(session, store.load());
            String encrypted = getTargetContext().getSharedPreferences("session", 0).getString("encrypted", "");
            assertFalse(encrypted.contains(session.token())); assertFalse(encrypted.contains(session.account()));
        } finally { store.clear(); }
        assertNull(store.load());
    }

    /** 不兼容协议和重复来源必须失败，不发布半份快照。 */
    public void testMalformedSnapshotRejected() throws Exception {
        String device = "{\"id\":\"a\",\"name\":\"测试\",\"connected\":true,\"readState\":\"ready\",\"observedAt\":100}";
        try { MobileApi.parse(new JSONObject("{\"version\":2}"), 0); fail("接受错误版本"); }
        catch (java.io.IOException expected) { /* 协议错误按预期被拒绝。 */ }
        try { MobileApi.parse(new JSONObject("{\"version\":1,\"serverTime\":100,\"devices\":[" + device + "," + device + "],\"tasks\":[]}"), 0); fail("接受重复来源"); }
        catch (java.io.IOException expected) { /* 唯一性错误按预期被拒绝。 */ }
    }
}
