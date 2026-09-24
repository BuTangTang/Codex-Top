package com.butang.codextop;

import java.util.List;

/** 聊天页只展示明确来源的消息和逐级回执，不把发送成功等同任务完成。 */
public final class ConversationData {
    /** 工具容器不需要实例。 */
    private ConversationData() { }
    public record Message(String id, String role, String text, String state, long createdAt) { }
    public record History(String source, String thread, String title, String device, boolean online,
                          List<Message> messages, Long olderCursor) { }

    /** 服务端的输入回执和助手回复状态分开校验，未知状态不升级成已接受。 */
    public static boolean validState(String role, String state) {
        if (state == null) return false;
        if ("assistant".equals(role)) return "received".equals(state) || "expired".equals(state);
        return "user".equals(role) && java.util.Set.of("server_received", "dispatching", "computer_received",
            "codex_received", "uncertain", "failed", "cancelled", "expired").contains(state);
    }

    /** 每个回执使用可区分的文案，未知状态不得伪装为接受或完成。 */
    public static String stateLabel(String state) {
        return switch (state) {
            case "server_received" -> "服务已收到，等待电脑";
            case "dispatching" -> "正在转发到电脑";
            case "computer_received" -> "电脑已收到";
            case "codex_received" -> "Codex 已接收";
            case "uncertain" -> "接收结果待确认";
            case "failed" -> "发送失败";
            case "cancelled" -> "已取消，未继续转发";
            case "expired" -> "消息已过保留期";
            case "received" -> "";
            default -> "接收状态未知";
        };
    }
}
