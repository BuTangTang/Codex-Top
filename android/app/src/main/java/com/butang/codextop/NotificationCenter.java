package com.butang.codextop;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;

/** 仅使用通用通知文字，默认锁屏隐藏内容，不上传任务正文。 */
public final class NotificationCenter {
    private static final String EVENTS = "task-events-v1";
    private static final String MONITOR = "monitor-v1";
    private final Context context;
    private final NotificationManager manager;

    /** 建立独立的任务与后台监控频道，由系统保留用户的声音和振动选择。 */
    public NotificationCenter(Context context) {
        this.context = context;
        manager = context.getSystemService(NotificationManager.class);
        NotificationChannel events = new NotificationChannel(EVENTS, "任务提醒", NotificationManager.IMPORTANCE_DEFAULT);
        events.setDescription("任务完成、待处理和出错时提醒");
        events.enableVibration(true);
        manager.createNotificationChannel(events);
        manager.createNotificationChannel(new NotificationChannel(MONITOR, "后台查看状态", NotificationManager.IMPORTANCE_LOW));
    }

    /** 同时检查应用通知和任务频道，避免权限授予但频道关闭时误报可用。 */
    public boolean enabled() {
        return manager.areNotificationsEnabled() && manager.getNotificationChannel(EVENTS).getImportance() != NotificationManager.IMPORTANCE_NONE;
    }

    /** 点击通知只打开本应用，Intent 不包含会话或任务标题等私密数据。 */
    private PendingIntent openApp() {
        return PendingIntent.getActivity(context, 0, new Intent(context, MainActivity.class), PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    /** 创建统一通知，锁屏只保留应用名；调用者区分测试与实际任务。 */
    private Notification.Builder builder(String channel, String title, String text) {
        return new Notification.Builder(context, channel).setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title).setContentText(text).setContentIntent(openApp())
            .setVisibility(Notification.VISIBILITY_PRIVATE).setAutoCancel(true);
    }

    /** 明确发送本机测试消息；这不代表服务器推送或后台接收已通过。 */
    public void test() {
        if (enabled()) manager.notify("test", 1, builder(EVENTS, "测试通知", "这是 Codex Top 的本机通知测试").build());
    }

    /** 对同一任务复用通知位置，新的状态替换旧的等待提示，默认不显示任务名。 */
    public void event(TaskData.Task task, SessionStore.Session session) {
        if (!enabled() || !java.util.Set.of("waiting", "failed", "completed").contains(task.phase())) return;
        String title = switch (task.phase()) {
            case "waiting" -> "需要你处理";
            case "failed" -> "任务执行出错";
            default -> "任务已完成";
        };
        Intent destination = ChatActivity.intent(context, session, task.sourceId(), task.id(), false);
        PendingIntent conversation = PendingIntent.getActivity(context, 0, destination, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        manager.notify(task.key(), 1, builder(EVENTS, title, "打开对应对话").setContentIntent(conversation).setTimeoutAfter(TaskData.EVENT_TTL_MS).build());
    }

    /** 取消已过时或已处理的任务提醒，防止旧通知继续要求用户行动。 */
    public void cancel(TaskData.Task task) { manager.cancel(task.key(), 1); }

    /** 退出登录时清除该应用的提醒，避免不同账号之间残留信息。 */
    public void clear() { manager.cancelAll(); }

    /** 常驻通知提供立即停止按钮，并明确显示监控是否连接正常。 */
    public Notification monitoring(String text) {
        Intent intent = new Intent(context, MonitorService.class).setAction(MonitorService.STOP);
        PendingIntent stop = PendingIntent.getService(context, 1, intent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return builder(MONITOR, "临时后台提醒", text).setOngoing(true).setAutoCancel(false)
            .addAction(new Notification.Action.Builder(null, "停止提醒", stop).build()).build();
    }

    /** 服务异常或到期时更新常驻状态，不能继续显示正在接收。 */
    public void updateMonitor(String text) { manager.notify(42, monitoring(text)); }
}
