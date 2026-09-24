package com.butang.codextop;

import org.junit.Test;
import java.util.List;
import static org.junit.Assert.*;

/** 用合成时间与状态检验通知资格，测试不访问用户数据。 */
public class TaskDataTest {
    /** 构建具有稳定来源标识的单条合成任务。 */
    private TaskData.Task task(String phase, String event, String turn, long eventAt) {
        return new TaskData.Task("task", "mac", "合成任务", "测试", phase, turn, event, eventAt, null);
    }

    /** 构建来源读取状态可控制的快照，不用真实时钟。 */
    private TaskData.Snapshot snapshot(TaskData.Task task, boolean connected, String state, long observed) {
        return new TaskData.Snapshot(100_000, 1_000, List.of(new TaskData.Device("mac", "测试电脑", connected, state, observed)), List.of(task));
    }

    /** 首次导入历史完成状态必须静默。 */
    @Test public void firstSnapshotDoesNotNotify() {
        assertTrue(TaskData.newEvents(null, snapshot(task("completed", "e1", "t1", 90_000), true, "ready", 99_000), 1_000).isEmpty());
    }

    /** 同一状态也可能是新一轮事件；只有事件证据变化才能提醒。 */
    @Test public void newTurnCanNotifyButRetriesCannot() {
        var before = snapshot(task("completed", "e1", "t1", 90_000), true, "ready", 99_000);
        var after = snapshot(task("completed", "e2", "t2", 99_000), true, "ready", 99_000);
        assertEquals(1, TaskData.newEvents(before, after, 1_000).size());
        assertTrue(TaskData.newEvents(after, after, 1_000).isEmpty());
    }

    /** 已离线、暂停、正在追平以及过期来源都不得生成行动提醒。 */
    @Test public void staleAndUnavailableSourcesNeverNotify() {
        var before = snapshot(task("running", "e1", "t1", 90_000), true, "ready", 99_000);
        var task = task("waiting", "e2", "t1", 99_000);
        assertTrue(TaskData.newEvents(before, snapshot(task, false, "ready", 99_000), 1_000).isEmpty());
        assertTrue(TaskData.newEvents(before, snapshot(task, true, "paused", 99_000), 1_000).isEmpty());
        assertTrue(TaskData.newEvents(before, snapshot(task, true, "syncing", 99_000), 1_000).isEmpty());
        assertTrue(TaskData.newEvents(before, snapshot(task, true, "ready", 30_000), 1_000).isEmpty());
    }

    /** 手机在没有新快照时仍会令旧数据过期，不能冻结“运行中”。 */
    @Test public void freshnessExpiresWithMonotonicTime() {
        var task = task("running", "e1", "t1", 90_000);
        var state = snapshot(task, true, "ready", 99_000);
        assertTrue(state.fresh(task, 1_000));
        assertFalse(state.fresh(task, 62_000));
    }

    /** 未知、停止和未来时间不冒充有效提醒，缺少轮次或事件也不发送。 */
    @Test public void evidenceAndTimeAreRequired() {
        var before = snapshot(task("running", "e1", "t1", 90_000), true, "ready", 99_000);
        for (String phase : List.of("stopped", "unknown", "idle")) assertTrue(TaskData.newEvents(before, snapshot(task(phase, "e2", "t1", 99_000), true, "ready", 99_000), 1_000).isEmpty());
        assertTrue(TaskData.newEvents(before, snapshot(task("waiting", "e2", "", 99_000), true, "ready", 99_000), 1_000).isEmpty());
        assertTrue(TaskData.newEvents(before, snapshot(task("waiting", "e2", "t1", 100_001), true, "ready", 99_000), 1_000).isEmpty());
        assertTrue(TaskData.newEvents(before, snapshot(task("waiting", "e2", "t1", -99_000), true, "ready", 99_000), 1_000).isEmpty());
    }

    /** 同一任务 ID 的两台来源电脑不允许相互覆盖。 */
    @Test public void keysIncludeSource() {
        var a = task("running", "e1", "t1", 90_000);
        var b = new TaskData.Task(a.id(), "windows", a.title(), a.project(), a.phase(), a.turnId(), a.eventId(), a.eventAt(), null);
        assertNotEquals(a.key(), b.key());
    }

    /** 旧事件乱序到达时不得因为事件 ID 变化而重复通知。 */
    @Test public void outOfOrderEventsAreSilent() {
        var before = snapshot(task("completed", "e2", "t1", 99_000), true, "ready", 99_000);
        var after = snapshot(task("waiting", "e1", "t1", 90_000), true, "ready", 99_000);
        assertTrue(TaskData.newEvents(before, after, 1_000).isEmpty());
    }

    /** 正式连接拒绝明文、嵌入密码、子路径和可误导用户的 URL 片段。 */
    @Test public void serverAddressPolicyProtectsCredentials() {
        assertEquals("https://top.example.com", MobileApi.normalizeServer(" https://top.example.com/ ", false));
        for (String bad : List.of("http://top.example.com", "https://user:secret@top.example.com", "https://top.example.com/path", "https://top.example.com?token=x", "https://top.example.com#other", "https://top.example.com:0")) {
            assertThrows(IllegalArgumentException.class, () -> MobileApi.normalizeServer(bad, false));
        }
        assertEquals("http://127.0.0.1:18765", MobileApi.normalizeServer("http://127.0.0.1:18765", true));
        assertThrows(IllegalArgumentException.class, () -> MobileApi.normalizeServer("http://192.168.1.1:18765", true));
    }
    /** 通知列表只保留三种事件且按真实事件时间排序，不改动原快照。 */
    @Test public void notificationListFiltersAndOrdersWithoutMutatingSnapshot() {
        var running = task("running", "run", "t1", 99_000);
        var completed = task("completed", "done", "t2", 98_000);
        var waiting = task("waiting", "wait", "t3", 99_500);
        var input = new TaskData.Snapshot(100_000, 1_000, List.of(), List.of(running, completed, waiting));
        assertEquals(List.of(waiting, completed), TaskData.notificationItems(input));
        assertEquals(3, input.tasks().size());
        assertEquals(9, TaskData.notificationItems(TaskData.demo(100_000_000, 0)).size());
    }
}
