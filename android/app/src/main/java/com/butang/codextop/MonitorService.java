package com.butang.codextop;

import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.IBinder;
import android.os.SystemClock;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/** 用户主动开启的一小时监控；不伪装成无限后台推送，不自动开机启动。 */
public final class MonitorService extends Service {
    public static final String STOP = "com.butang.codextop.STOP";
    public static volatile boolean running;
    private final ScheduledExecutorService worker = Executors.newSingleThreadScheduledExecutor();
    private final MobileApi api = new MobileApi();
    private volatile boolean closed;
    private long started;
    private NotificationCenter notices;
    private TaskData.Snapshot previous;
    private final Map<String, TaskData.Task> active = new HashMap<>();
    private final Map<String, String> delivered = new HashMap<>();

    /** 服务不提供跨应用绑定能力。 */
    @Override public IBinder onBind(Intent intent) { return null; }

    /** 初始化通知频道；不在创建时读取或发布任务。 */
    @Override public void onCreate() { super.onCreate(); notices = new NotificationCenter(this); }

    /** 只响应用户显式开始/停止；进程被终止后不凭空恢复监控。 */
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && STOP.equals(intent.getAction())) { finish(); return START_NOT_STICKY; }
        if (!running) {
            started = SystemClock.elapsedRealtime();
            startForeground(42, notices.monitoring("正在连接，最多持续 1 小时"), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
            running = true;
            worker.scheduleWithFixedDelay(this::poll, 0, 15, TimeUnit.SECONDS);
        }
        return START_NOT_STICKY;
    }

    /** 顺序轮询并按事件去重；网络失败不把旧快照标为刚更新。 */
    private void poll() {
        if (closed) return;
        long elapsed = SystemClock.elapsedRealtime();
        if (elapsed - started >= 3_600_000) { finish(); return; }
        SessionStore.Session session = new SessionStore(this).load();
        if (session == null) { finish(); return; }
        try {
            TaskData.Snapshot next = api.snapshot(session);
            synchronized (this) {
            if (closed) return;
            if (previous != null && next.serverTime() < previous.serverTime()) throw new IllegalStateException("服务返回旧快照");
            Map<String, TaskData.Task> current = new HashMap<>();
            for (TaskData.Task task : next.tasks()) current.put(task.key(), task);
            // 来源离线、等待已解决或任务已移出时，先撤旧通知，再处理新的状态事件。
            active.entrySet().removeIf(entry -> {
                TaskData.Task task = current.get(entry.getKey());
                boolean obsolete = task == null || !next.fresh(task, elapsed) || !task.eventId().equals(entry.getValue().eventId())
                    || next.now(elapsed) - task.eventAt() > TaskData.EVENT_TTL_MS;
                if (obsolete) notices.cancel(entry.getValue());
                return obsolete;
            });
            for (TaskData.Task task : TaskData.newEvents(previous, next, elapsed)) {
                String event = task.turnId() + "\u0000" + task.eventId();
                if (!event.equals(delivered.get(task.key())) && notices.enabled()) {
                    notices.event(task, session);
                    active.put(task.key(), task);
                    delivered.put(task.key(), event);
                }
            }
            delivered.keySet().retainAll(current.keySet());
            previous = next;
            if (!closed) notices.updateMonitor("已连接；剩余 " + Math.max(1, (3_600_000 - elapsed + started) / 60_000) + " 分钟");
            }
        } catch (Exception error) {
            synchronized (this) {
            if (closed) return;
            if (error instanceof MobileApi.ApiException && ((MobileApi.ApiException) error).status == 401) {
                new SessionStore(this).clearIf(session); finish(); return;
            }
            for (TaskData.Task task : active.values()) notices.cancel(task);
            active.clear();
            notices.updateMonitor("连接中断，正在重试；旧状态不再提醒");
            }
        }
    }

    /** Android 15 的系统时限到达时立即停止，避免超时导致应用崩溃。 */
    @Override public void onTimeout(int startId, int fgsType) { finish(); }

    /** 停止后先阻止异步回调，再撤销前台通知和服务。 */
    private synchronized void finish() {
        closed = true;
        running = false;
        worker.shutdownNow();
        for (TaskData.Task task : active.values()) notices.cancel(task);
        active.clear();
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    /** 销毁时释放线程；当前未结束的网络请求返回后必须检查 closed。 */
    @Override public void onDestroy() { finish(); super.onDestroy(); }
}
