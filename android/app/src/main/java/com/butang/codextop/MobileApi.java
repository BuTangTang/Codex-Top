package com.butang.codextop;

import android.os.SystemClock;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** 独立手机接口客户端；只能在工作线程调用，不记录请求正文、账号或凭据。 */
public final class MobileApi {
    public static final String PREFIX = "/api/mobile/v1";

    public static final class ApiException extends IOException {
        public final int status;
        public final String code;
        /** 保留可判断的 HTTP 状态；错误内容只使用客户端固定文案。 */
        public ApiException(int status, String message) { this(status, "", message); }
        /** 仅保存白名单错误码，允许界面区分明确拒绝和结果未知。 */
        public ApiException(int status, String code, String message) { super(message); this.status = status; this.code = code; }
    }

    /** 禁止含密码、路径、查询或片段的地址；正式服务仅接受 HTTPS 根地址。 */
    public static String normalizeServer(String text, boolean debug) throws IllegalArgumentException {
        try {
            URI uri = URI.create(text.trim());
            String host = uri.getHost();
            boolean local = Set.of("localhost", "127.0.0.1", "10.0.2.2").contains(host == null ? "" : host);
            if (host == null || uri.getRawUserInfo() != null || uri.getRawQuery() != null || uri.getRawFragment() != null
                    || (!uri.getPath().isEmpty() && !uri.getPath().equals("/"))
                    || !(uri.getScheme().equals("https") || (debug && local && uri.getScheme().equals("http")))
                    || uri.getPort() > 65535 || uri.getPort() == 0) throw new IllegalArgumentException();
            return uri.getScheme() + "://" + uri.getRawAuthority();
        } catch (RuntimeException invalid) { throw new IllegalArgumentException("请填写 HTTPS 服务根地址，例如 https://top.example.com"); }
    }

    /** 发起有超时和大小上限的请求；禁止重定向，避免把登录秘密转发给其他地址。 */
    private JSONObject request(String server, String path, String method, String token, JSONObject body) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) URI.create(server + PREFIX + path).toURL().openConnection();
        try {
            connection.setInstanceFollowRedirects(false);
            connection.setConnectTimeout(8_000);
            connection.setReadTimeout(8_000);
            connection.setRequestMethod(method);
            connection.setRequestProperty("Accept", "application/json");
            if (token != null) connection.setRequestProperty("Authorization", "Bearer " + token);
            if (body != null) {
                connection.setDoOutput(true);
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                try (var output = connection.getOutputStream()) { output.write(body.toString().getBytes(StandardCharsets.UTF_8)); }
            }
            int status = connection.getResponseCode();
            if (status < 200 || status >= 300) {
                String code = "";
                // 错误页可能来自代理；限制大小且只接受固定错误码，不展示服务原文。
                try (InputStream input = connection.getErrorStream()) {
                    if (input != null) code = knownError(new JSONObject(readBody(input, 4096)).optString("error", ""), status);
                } catch (Exception ignored) { /* 损坏的错误正文不改变已收到的 HTTP 状态。 */ }
                throw new ApiException(status, code, errorMessage(status, code));
            }
            if (status == 204) return new JSONObject();
            try (InputStream input = connection.getInputStream()) {
                return new JSONObject(readBody(input, 1_048_576));
            }
        } finally { connection.disconnect(); }
    }

    /** 按字节限制响应，成功正文和错误正文均不能无限占用手机内存。 */
    private static String readBody(InputStream input, int maximum) throws IOException {
        try (ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int length;
            while ((length = input.read(buffer)) != -1) {
                if (output.size() + length > maximum) throw new IOException("服务数据超过大小限制");
                output.write(buffer, 0, length);
            }
            return output.toString(StandardCharsets.UTF_8.name());
        }
    }

    /** 错误码必须与状态一致，未知或代理返回内容不进入界面判定。 */
    static String knownError(String code, int status) {
        if (status == 409 && Set.of("computer_offline", "message_id_conflict").contains(code)) return code;
        if (status == 429 && "message_quota".equals(code)) return code;
        return "";
    }

    /** 使用固定本地文案解释明确拒绝，服务收到和 Codex 收到仍由回执区分。 */
    static String errorMessage(int status, String code) {
        return switch (code) {
            case "computer_offline" -> "电脑已离线，消息未接收；请等电脑上线后重试";
            case "message_id_conflict" -> "消息标识冲突，本次内容未接收；请核对后重新发送";
            case "message_quota" -> "消息数量已达上限，本次内容未接收";
            default -> switch (status) {
                case 400 -> "请求无效，请刷新后重试";
                case 401 -> "账号或密码不正确，或登录已失效";
                case 403 -> "当前账号没有访问权限";
                case 404 -> "对话不可用，可能已取消共享或服务尚未支持对话";
                case 409 -> "消息状态已变化，请刷新确认";
                case 429 -> "操作过于频繁，请稍后重试";
                default -> "服务暂不可用，请检查地址或稍后重试";
            };
        };
    }

    /** 在网络请求前复核登录指纹，旧通知不能借新账号读取同名对话。 */
    private static void validateRoute(SessionStore.Session session, ConversationRoute route) throws IOException {
        if (!route.scope().equals(ConversationRoute.scope(session.server(), session.token()))) throw new IOException("对话不属于当前登录，请重新打开");
    }

    /** 用自己的服务账号登录，返回服务签发的独立会话，不缓存明文密码。 */
    public SessionStore.Session login(String server, String username, String password) throws Exception {
        JSONObject response = request(server, "/sessions", "POST", null,
            new JSONObject().put("username", username).put("password", password).put("deviceName", android.os.Build.MODEL));
        String token = response.getString("token");
        if (!token.matches("[A-Za-z0-9._~-]{24,2048}")) throw new IOException("服务返回的登录信息无效");
        return new SessionStore.Session(server, token, limited(response.getString("account"), 120));
    }

    /** 获取一个完整快照；解析失败不发布半份结果，避免重复或丢失来源造成误判。 */
    public TaskData.Snapshot snapshot(SessionStore.Session session) throws Exception {
        return parse(request(session.server(), "/snapshot", "GET", session.token(), null), SystemClock.elapsedRealtime());
    }

    /** 读取指定电脑的已有对话；响应中每条消息都核对复合身份。 */
    public ConversationData.History history(SessionStore.Session session, ConversationRoute route, Long before) throws Exception {
        validateRoute(session, route);
        if (before != null && before <= 0) throw new IOException("消息游标无效");
        String path = "/conversations/" + route.source() + "/" + route.thread() + "/messages";
        if (before != null) path += "?before=" + before;
        JSONObject json = request(session.server(), path, "GET", session.token(), null);
        ConversationData.History history = parseHistory(json, route);
        if (before != null && history.olderCursor() != null && history.olderCursor() >= before) throw new IOException("消息游标未前进");
        return history;
    }

    /** 发送时保留客户端消息 ID，超时后只能用同一 ID 确认，不能自动换 ID 重投。 */
    public void send(SessionStore.Session session, ConversationRoute route, String id, String text) throws Exception {
        validateRoute(session, route);
        if (text.isBlank() || text.length() > 8000 || text.indexOf('\0') >= 0) throw new IOException("消息为空或超过长度限制");
        JSONObject result = request(session.server(), "/conversations/" + route.source() + "/" + route.thread() + "/messages", "POST", session.token(),
            new JSONObject().put("id", identifier(id)).put("text", text));
        ConversationData.Message receipt = parseMessage(result, route);
        if (!id.equals(receipt.id()) || !"user".equals(receipt.role())
                || (!"expired".equals(receipt.state()) && !text.equals(receipt.text()))) throw new IOException("消息回执不匹配");
    }

    /** 限制消息数量、角色、正文与游标，拒绝错账号路由或混入其他电脑的消息。 */
    static ConversationData.History parseHistory(JSONObject json, ConversationRoute route) throws Exception {
        if (!route.source().equals(json.getString("sourceId")) || !route.thread().equals(json.getString("threadId"))) throw new IOException("对话路由不匹配");
        JSONArray items = json.getJSONArray("messages");
        if (items.length() > 100) throw new IOException("消息数量超限");
        List<ConversationData.Message> messages = new ArrayList<>(); Set<String> ids = new HashSet<>();
        for (int index = 0; index < items.length(); index++) {
            JSONObject item = items.getJSONObject(index);
            ConversationData.Message message = parseMessage(item, route);
            if (!ids.add(message.id())) throw new IOException("消息身份不匹配");
            messages.add(message);
        }
        JSONObject task = json.getJSONObject("task"), device = json.getJSONObject("device");
        if (!route.source().equals(device.getString("id")) || !route.thread().equals(task.getString("id"))) throw new IOException("来源身份不匹配");
        if (!json.has("olderCursor")) throw new IOException("消息游标缺失");
        Long cursor = json.isNull("olderCursor") ? null : positiveInteger(json, "olderCursor");
        if (cursor != null && cursor <= 0) throw new IOException("消息游标无效");
        return new ConversationData.History(route.source(), route.thread(), limited(task.getString("title"), 160),
            limited(device.getString("name"), 80), device.getBoolean("connected"), List.copyOf(messages), cursor);
    }

    /** 历史和发送回执共用严格校验，拒绝错来源、错误角色或伪造的接受状态。 */
    private static ConversationData.Message parseMessage(JSONObject item, ConversationRoute route) throws Exception {
        String id = identifier(item.getString("id")), role = item.getString("role"), state = item.getString("state");
        if (!route.source().equals(item.getString("sourceId")) || !route.thread().equals(item.getString("threadId"))
                || !ConversationData.validState(role, state)) throw new IOException("消息身份或状态不匹配");
        String text = item.getString("text");
        if (text.length() > 16000 || text.indexOf('\0') >= 0 || (!"expired".equals(state) && text.isBlank())
                || ("expired".equals(state) && !text.isEmpty())) throw new IOException("消息正文无效");
        return new ConversationData.Message(id, role, text, state, positiveInteger(item, "createdAt"));
    }

    /** 时间和游标必须为正整数，拒绝 JSON 字符串、布尔或小数的隐式转换。 */
    private static long positiveInteger(JSONObject item, String key) throws Exception {
        Object value = item.get(key);
        if (!(value instanceof Integer || value instanceof Long) || ((Number) value).longValue() <= 0) throw new IOException("消息时间或游标无效");
        return ((Number) value).longValue();
    }

    /** 主动撤销当前手机会话；断网失败交给界面明确说明。 */
    public void logout(SessionStore.Session session) throws Exception {
        request(session.server(), "/sessions/current", "DELETE", session.token(), null);
    }

    /** 严格解析上限、唯一键和时间；所有绝对时间统一为毫秒。 */
    static TaskData.Snapshot parse(JSONObject json, long received) throws Exception {
        if (json.getInt("version") != 1) throw new IOException("服务协议版本不兼容");
        long time = json.getLong("serverTime");
        if (time <= 0) throw new IOException("服务时间无效");
        JSONArray sources = json.getJSONArray("devices");
        JSONArray rows = json.getJSONArray("tasks");
        if (sources.length() > 100 || rows.length() > 500) throw new IOException("任务数量超过本版上限");
        List<TaskData.Device> devices = new ArrayList<>();
        List<TaskData.Task> tasks = new ArrayList<>();
        Set<String> deviceIds = new HashSet<>();
        Set<String> taskIds = new HashSet<>();
        for (int i = 0; i < sources.length(); i++) {
            JSONObject item = sources.getJSONObject(i);
            String id = identifier(item.getString("id"));
            if (!deviceIds.add(id)) throw new IOException("重复的来源设备");
            devices.add(new TaskData.Device(id, limited(item.getString("name"), 80), item.getBoolean("connected"),
                limited(item.getString("readState"), 40), item.getLong("observedAt")));
        }
        for (int i = 0; i < rows.length(); i++) {
            JSONObject item = rows.getJSONObject(i);
            TaskData.Task task = new TaskData.Task(identifier(item.getString("id")), identifier(item.getString("sourceId")),
                limited(item.getString("title"), 160), limited(item.getString("project"), 80), limited(item.getString("phase"), 40),
                limited(item.optString("turnId", ""), 128), limited(item.optString("eventId", ""), 128), item.optLong("eventAt", 0),
                item.isNull("startedAt") ? null : item.getLong("startedAt"));
            if (!taskIds.add(task.key())) throw new IOException("重复的任务");
            tasks.add(task);
        }
        return new TaskData.Snapshot(time, received, List.copyOf(devices), List.copyOf(tasks));
    }

    /** 限定来源与任务标识符，避免控制字符和复合键冲突。 */
    private static String identifier(String value) throws IOException {
        if (!value.matches("[A-Za-z0-9_-]{1,128}")) throw new IOException("服务标识符无效");
        return value;
    }

    /** 限制显示字符串长度并去掉控制字符；不把服务错误正文直接展示给用户。 */
    private static String limited(String value, int max) throws IOException {
        if (value.length() > max) throw new IOException("服务字段超过长度限制");
        return value.replaceAll("[\\p{Cntrl}]", " ");
    }
}
