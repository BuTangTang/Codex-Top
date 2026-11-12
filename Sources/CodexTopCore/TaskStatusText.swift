import Foundation

/// 任务行第二行的文字。面板和设备读取接口（REQ-005）共用这一处，两边一字不差。
public enum TaskStatusText {
    /// “刚完成”一段：本轮执行已结束 · 刚刚／N 分钟前。
    public static func finished(at finishedAt: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(finishedAt)) / 60
        return "本轮执行已结束 · \(minutes < 1 ? "刚刚" : "\(minutes) 分钟前")"
    }
    /// “· N 个子任务”，没有子任务时不写。
    public static func children(_ count: Int) -> String? { count > 0 ? "· \(count) 个子任务" : nil }
    /// 在等你处理时的“· 已等 N 分钟”，至少 1 分钟。
    public static func waited(since: Date, now: Date) -> String {
        "· 已等 \(max(1, Int(now.timeIntervalSince(since)) / 60)) 分钟"
    }
    /// 整行文字：刚完成写完成多久；未结束写活动说明、子任务数、等了多久；已结束的面板不显示第二行，这里给活动说明。
    public static func line(activity: TaskActivity, childCount: Int, freshFinishedAt: Date?, now: Date) -> String {
        if let freshFinishedAt { return finished(at: freshFinishedAt, now: now) }
        var parts = [activity.detail]
        guard !activity.phase.isFinished else { return activity.detail }
        if let children = children(childCount) { parts.append(children) }
        if activity.phase == .waiting, let since = activity.waitingStartedAt { parts.append(waited(since: since, now: now)) }
        return parts.joined(separator: " ")
    }
}
