using System.Globalization;
using System.Text.Json;

namespace CodexTop.Core;

public enum Phase { Waiting, Failed, Running, Unknown, Idle, Stopped, Completed }
public enum Placement { Top, Floating, Orb, Tray }

public static class PhaseInfo
{
    public static string Label(this Phase phase) => phase switch {
        Phase.Waiting => "待处理", Phase.Failed => "出错", Phase.Running => "运行中",
        Phase.Completed => "已完成", Phase.Stopped => "已停止", Phase.Idle => "未运行", _ => "状态未知"
    };
    public static bool IsActive(this Phase p) => p is Phase.Running or Phase.Waiting;
    public static bool IsFinished(this Phase p) => p is Phase.Completed or Phase.Stopped;
}

public sealed record Activity
{
    public Phase Phase { get; set; } = Phase.Unknown;
    public string Detail { get; set; } = "尚无可识别的活动记录";
    public DateTimeOffset? LastEventAt { get; set; }
    public DateTimeOffset? StartedAt { get; set; }
    public DateTimeOffset? WaitingStartedAt { get; set; }
    public string? TurnId { get; set; }
    public Activity Effective(DateTimeOffset now) => Phase == Phase.Running && LastEventAt is { } last && now - last > TimeSpan.FromMinutes(15)
        ? this with { Phase = Phase.Unknown, Detail = "较久未收到新活动，请回到 Codex 查看" } : this with { };
    public string Timer(DateTimeOffset now)
    {
        if (Phase is not (Phase.Running or Phase.Waiting)) return "";
        var end = Phase == Phase.Waiting ? WaitingStartedAt : now;
        if (StartedAt is not { } start || end is not { } finish || finish < start)
            return Phase == Phase.Running ? "--:--" : "";
        var seconds = (long)(finish - start).TotalSeconds;
        return $"{seconds / 60:00}:{seconds % 60:00}";
    }
}

public sealed record CodexTask(string Id, string Title, string Project, DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt, string? ParentId, string RolloutPath, Activity Activity)
{
    public Uri? DeepLink => Guid.TryParse(Id, out _) ? new Uri($"codex://threads/{Id}") : null;
}
public sealed record TaskRow(CodexTask Root, CodexTask Source)
{
    public Activity Activity => Source.Activity;
    public CodexTask NavigationTarget => Activity.Phase == Phase.Waiting ? Source : Root;
}
public sealed record SourceSnapshot(IReadOnlyList<CodexTask> Tasks, long BytesRead, DateTimeOffset ObservedAt, string? Warning = null);
public sealed record QuotaWindow(int Minutes, double UsedPercent, DateTimeOffset? ResetsAt)
{
    public int Remaining => (int)Math.Round(Math.Clamp(100 - UsedPercent, 0, 100));
    public string Label => Minutes switch { 300 => "5 小时", 10080 => "每周", < 60 => $"{Minutes} 分钟", _ when Minutes % 1440 == 0 => $"{Minutes / 1440} 天", _ => $"{Minutes / 60.0:0.#} 小时" };
}
public sealed record QuotaSnapshot(IReadOnlyList<QuotaWindow> Windows, DateTimeOffset ObservedAt);

internal static class JsonValue
{
    public static JsonElement Field(this JsonElement e, string key) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var value) ? value : default;
    public static string? Text(this JsonElement e, string key) => e.Field(key).ValueKind == JsonValueKind.String ? e.Field(key).GetString() : null;
    public static DateTimeOffset? Date(this JsonElement e, string key)
    {
        var value = e.Field(key);
        if (value.ValueKind == JsonValueKind.String && DateTimeOffset.TryParse(value.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at)) return at;
        return null;
    }
}
