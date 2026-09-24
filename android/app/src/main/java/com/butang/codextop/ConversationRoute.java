package com.butang.codextop;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/** 对话地址绑定登录会话、来源电脑和任务，名称不参与路由。 */
public record ConversationRoute(String scope, String source, String thread) {
    /** 在边界校验不透明标识，禁止路径字符、控制字符与缺失来源。 */
    public ConversationRoute {
        if (scope == null || !scope.matches("[a-f0-9]{64}") || !valid(source) || !valid(thread)) throw new IllegalArgumentException("无效对话地址");
    }

    /** 检查来源或会话标识与服务端现有契约一致。 */
    private static boolean valid(String id) { return id != null && id.matches("[A-Za-z0-9_-]{1,128}"); }

    /** 生成不可逆的登录会话指纹，通知和 Intent 不携带登录令牌。 */
    public static String scope(String server, String token) {
        if (server == null || token == null || server.isBlank() || token.isBlank() || server.indexOf('\0') >= 0 || token.indexOf('\0') >= 0) throw new IllegalArgumentException("无效登录身份");
        try {
            byte[] hash = MessageDigest.getInstance("SHA-256").digest((server + "\u0000" + token).getBytes(StandardCharsets.UTF_8));
            StringBuilder value = new StringBuilder();
            for (byte part : hash) value.append(String.format(java.util.Locale.ROOT, "%02x", part & 255));
            return value.toString();
        } catch (java.security.NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
    }

    /** 返回仅含不透明身份的内部地址，不将用户名、标题或正文带入通知。 */
    public String address() { return "codextop://conversation/" + scope + "/" + source + "/" + thread; }
}
