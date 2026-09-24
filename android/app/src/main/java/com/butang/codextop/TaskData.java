package com.butang.codextop;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** 手机只消费来源端给出的状态；不从标题、更新时间或通知反推任务结果。 */
public final class TaskData {
    public static final long FRESH_MS = 60_000;
    public static final long EVENT_TTL_MS = 120_000;

    /** 容纳只读数据模型，禁止实例化工具容器。 */
    private TaskData() { }

    public record Device(String id, String name, boolean connected, String readState, long observedAt) { }
    public record Task(String id, String sourceId, String title, String project, String phase,
                       String turnId, String eventId, long eventAt, Long startedAt) {
        /** 来源与任务共同组成键，避免不同电脑的同名或同 ID 任务相互覆盖。 */
        public String key() { return sourceId + "\u0000" + id; }
    }
    public record Snapshot(long serverTime, long receivedElapsed, List<Device> devices, List<Task> tasks) {
        /** 用单调时间推进服务端基准，不依赖手机墙钟是否准确。 */
        public long now(long elapsed) { return serverTime + Math.max(0, elapsed - receivedElapsed); }
        /** 按来源 ID 寻找电脑；来源丢失时保持未知而不是猜测。 */
        public Device device(String id) {
            for (Device device : devices) if (device.id().equals(id)) return device;
            return null;
        }
        /** 连接、读取状态和观察时间必须同时有效，旧记录不计入实时统计。 */
        public boolean fresh(Task task, long elapsed) {
            Device device = device(task.sourceId());
            long age = device == null ? -1 : now(elapsed) - device.observedAt();
            return device != null && device.connected() && device.readState().equals("ready")
                && age >= 0 && age <= FRESH_MS;
        }
    }

    /** 保留来源已定义的七种状态，未知值统一显示未知。 */
    public static String label(String phase) {
        return switch (phase) {
            case "running" -> "运行中";
            case "waiting" -> "待处理";
            case "completed" -> "已完成";
            case "failed" -> "出错";
            case "stopped" -> "已停止";
            case "idle" -> "未运行";
            default -> "状态未知";
        };
    }

    /** 通知只接受明确完成、需要处理和出错三种状态。 */
    public static boolean notifiable(String phase) {
        return phase.equals("completed") || phase.equals("waiting") || phase.equals("failed");
    }

    /** 计算相邻快照中新发生的事件；首次加载、旧事件、未知来源和重复事件均不提醒。 */
    public static List<Task> newEvents(Snapshot before, Snapshot after, long elapsed) {
        List<Task> result = new ArrayList<>();
        if (before == null) return result;
        Map<String, Task> previous = new HashMap<>();
        for (Task task : before.tasks()) previous.put(task.key(), task);
        for (Task task : after.tasks()) {
            Task old = previous.get(task.key());
            long age = after.now(elapsed) - task.eventAt();
            if (old != null && !task.eventId().isEmpty() && !task.turnId().isEmpty()
                    && !old.eventId().equals(task.eventId()) && task.eventAt() > old.eventAt() && notifiable(task.phase())
                    && after.fresh(task, elapsed) && age >= 0 && age <= EVENT_TTL_MS) result.add(task);
        }
        return result;
    }

    /** 仅按事件时间降序展示可通知状态，来源过期的历史记录由界面明确标注。 */
    public static List<Task> notificationItems(Snapshot snapshot) {
        List<Task> items = new ArrayList<>();
        for (Task task : snapshot.tasks()) if (notifiable(task.phase())) items.add(task);
        items.sort(java.util.Comparator.comparingLong(Task::eventAt).reversed());
        return items;
    }

    /** 创建九条明确标识的合成通知，布局测试不依赖任何真实任务。 */
    public static Snapshot demo(long time, long elapsed) {
        String[] titles = {"登录页面调整", "通知功能测试", "安卓安装包构建", "连接状态检查", "登录异常修复", "消息去重验证", "手机通知适配", "服务连接测试", "设置页面调整"};
        String[] phases = {"waiting", "completed", "failed", "completed", "completed", "waiting", "completed", "failed", "completed"};
        List<Task> items = new ArrayList<>();
        for (int i = 0; i < titles.length; i++) {
            long event = time - (i < 5 ? (i + 1) * 120_000L : 86_400_000L + i * 120_000L);
            items.add(new Task("demo-" + i, new String[]{"mac-demo", "mini-demo", "windows-demo"}[i % 3], titles[i], "合成示例", phases[i], "turn-" + i, "event-" + i, event, null));
        }
        return new Snapshot(time, elapsed, List.of(new Device("mac-demo", "MacBook Pro", true, "ready", time), new Device("mini-demo", "Mac mini", true, "ready", time), new Device("windows-demo", "Windows PC", false, "ready", time - 120_000)), items);
    }
}
