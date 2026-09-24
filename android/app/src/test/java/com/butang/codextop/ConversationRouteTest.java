package com.butang.codextop;

import org.junit.Test;
import static org.junit.Assert.*;

/** 独立路由测试使用合成令牌，不依赖安卓设备或任何真实会话。 */
public class ConversationRouteTest {
    /** 同名会话跨来源、换登录和换服务器都必须生成不同路由。 */
    @Test public void isolatesComputerSessionAndServer() {
        String scope = ConversationRoute.scope("https://example.com", "synthetic-a");
        assertNotEquals(scope, ConversationRoute.scope("https://example.com", "synthetic-b"));
        assertNotEquals(scope, ConversationRoute.scope("https://other.example.com", "synthetic-a"));
        assertNotEquals(new ConversationRoute(scope, "mac", "thread").address(), new ConversationRoute(scope, "pc", "thread").address());
        assertFalse(new ConversationRoute(scope, "mac", "thread").address().contains("synthetic-a"));
    }
    /** 路径字符不能突破来源和会话两级身份。 */
    @Test(expected = IllegalArgumentException.class) public void rejectsAmbiguousRoute() {
        new ConversationRoute("0".repeat(64), "../mac", "thread");
    }
    /** 未知回执与服务接受绝不展示为任务完成或 Codex 已接受。 */
    @Test public void separatesReceipts() {
        assertEquals("接收状态未知", ConversationData.stateLabel("unknown"));
        assertNotEquals(ConversationData.stateLabel("server_received"), ConversationData.stateLabel("codex_received"));
        assertEquals("接收结果待确认", ConversationData.stateLabel("uncertain"));
    }
    /** 输入与回复的状态不能互换，尤其不能把普通 received 当作 Codex 接收。 */
    @Test public void validatesRoleAndReceiptTogether() {
        assertTrue(ConversationData.validState("user", "server_received"));
        assertTrue(ConversationData.validState("user", "codex_received"));
        assertTrue(ConversationData.validState("assistant", "received"));
        assertTrue(ConversationData.validState("assistant", "expired"));
        assertFalse(ConversationData.validState("user", "received"));
        assertFalse(ConversationData.validState("assistant", "codex_received"));
        assertFalse(ConversationData.validState("system", "received"));
        assertFalse(ConversationData.validState("user", "unknown"));
        assertFalse(ConversationData.validState("user", null));
    }
    /** 登录指纹分隔符不能被输入值混淆成另一个账号的同一指纹。 */
    @Test(expected = IllegalArgumentException.class) public void rejectsScopeDelimiter() {
        ConversationRoute.scope("https://example.com\0account", "token");
    }
    /** 缺失登录不能生成看似正常但没有身份约束的地址。 */
    @Test(expected = IllegalArgumentException.class) public void rejectsMissingSession() {
        ConversationRoute.scope("https://example.com", null);
    }
}
