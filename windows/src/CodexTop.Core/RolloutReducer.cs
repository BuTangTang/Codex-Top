using System.Text.Json;

namespace CodexTop.Core;

// State rules adapted from BuTangTang/Codex-Top (GPL-3.0).
public sealed class RolloutReducer
{
    public Activity Activity { get; private set; } = new();
    private readonly HashSet<string> synchronous = [];
    private readonly HashSet<string> asynchronous = [];
    private bool anonymousWait;
    public void Consume(ReadOnlySpan<byte> line)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(line.ToArray()); } catch (JsonException) { return; }
        using (doc)
        {
            var root = doc.RootElement; var payload = root.Field("payload");
            string? kind = root.Text("type"), type = payload.Text("type"), turn = payload.Text("turn_id");
            var at = root.Date("timestamp");
            if (at is { } time && Activity.LastEventAt is { } previous && time < previous) return;
            bool start = kind == "event_msg" && type is "task_started" or "turn_started";
            bool terminal = kind == "event_msg" && type is "task_complete" or "task_completed" or "turn_complete" or "turn_completed" or "turn_aborted" or "task_cancelled" or "turn_cancelled" or "task_failed" or "turn_failed";
            bool user = kind == "response_item" && type == "message" && payload.Text("role") == "user";
            if (!start && turn is not null && Activity.TurnId is { } current && current != turn) return;
            if (Activity.Phase == Phase.Failed && !start && !user && !(kind == "event_msg" && type is "user_message" or "user_input")) return;
            bool handled = true;
            if (start)
            {
                if (turn is not null && turn == Activity.TurnId && Activity.StartedAt is not null) return;
                synchronous.Clear(); asynchronous.Clear(); anonymousWait = false;
                Activity = new() { Phase = Phase.Running, Detail = "正在处理任务", StartedAt = payload.Date("started_at") ?? at, TurnId = turn, LastEventAt = at };
                return;
            }
            if (kind == "event_msg")
            {
                switch (type)
                {
                    case "task_complete": case "task_completed": case "turn_complete": case "turn_completed":
                        if (asynchronous.Count > 0 || anonymousWait) Wait(at, "等待你的回答");
                        else { Activity.Phase = Phase.Completed; Activity.Detail = "本轮执行已结束"; Activity.WaitingStartedAt = null; }
                        synchronous.Clear(); break;
                    case "turn_aborted": case "task_cancelled": case "turn_cancelled":
                        Finish(Phase.Stopped, "本轮执行已停止"); break;
                    case "task_failed": case "turn_failed":
                        Finish(Phase.Failed, "执行遇到问题，请回到 Codex 查看"); break;
                    case "request_user_input": case "user_input_requested": case "exec_approval_request": case "apply_patch_approval_request":
                        var call = payload.Text("call_id") ?? payload.Text("request_id");
                        if (call != null) synchronous.Add(call); else anonymousWait = true;
                        Wait(at, "等待你的输入或确认"); break;
                    case "user_message": case "user_input":
                        Continue(at); break;
                    case "approval_resolved":
                        var approval = payload.Text("call_id") ?? payload.Text("request_id");
                        if (approval != null && !synchronous.Remove(approval)) break;
                        anonymousWait = false;
                        if (synchronous.Count == 0 && asynchronous.Count == 0) Active(at, "已收到确认，正在继续"); break;
                    case "agent_message": case "agent_reasoning":
                        if (!Activity.Phase.IsFinished() && Activity.Phase != Phase.Waiting) Active(at, "正在处理任务"); break;
                    case "item_completed":
                        var item = payload.Field("item"); var itemType = item.Text("type")?.ToLowerInvariant();
                        if (itemType is "usermessage" or "user_message") Continue(at);
                        else if (itemType is "commandexecution" or "filechange" or "reasoning" or "mcptoolcall")
                        { if (Activity.Phase != Phase.Waiting && !Activity.Phase.IsFinished()) Active(at, "正在执行任务"); }
                        break;
                    default: handled = false; break;
                }
            }
            else if (kind == "response_item")
            {
                if (user) Continue(at);
                else if (type is "function_call" or "custom_tool_call")
                {
                    var name = payload.Text("name") ?? "";
                    if (name.EndsWith("request_user_input_async", StringComparison.Ordinal))
                    { asynchronous.Add(payload.Text("call_id") ?? "anonymous"); Wait(at, "等待你的回答"); }
                    else if (name.EndsWith("request_user_input", StringComparison.Ordinal))
                    { synchronous.Add(payload.Text("call_id") ?? "anonymous"); Wait(at, "等待你的回答"); }
                    else if (Activity.Phase != Phase.Waiting && !Activity.Phase.IsFinished()) Active(at, "正在执行任务");
                }
                else if (type is "function_call_output" or "custom_tool_call_output")
                {
                    if (payload.Text("call_id") is { } id && synchronous.Remove(id) && synchronous.Count == 0 && asynchronous.Count == 0 && !anonymousWait)
                        Active(at, "已收到回答，正在继续");
                }
                else if (type is "reasoning" or "message") { }
                else handled = false;
            }
            else handled = false;
            if (handled && at is not null) Activity.LastEventAt = at;
        }
    }
    private void Continue(DateTimeOffset? at)
    { synchronous.Clear(); asynchronous.Clear(); anonymousWait = false; Active(at, "收到输入，正在继续"); }
    private void Active(DateTimeOffset? at, string detail)
    {
        if (Activity.Phase.IsFinished() || Activity.Phase == Phase.Failed) { Activity.StartedAt = null; Activity.TurnId = null; }
        Activity.Phase = Phase.Running; Activity.Detail = detail; Activity.WaitingStartedAt = null;
    }
    private void Wait(DateTimeOffset? at, string detail)
    {
        if (Activity.Phase != Phase.Waiting)
        { if (Activity.Phase.IsFinished()) { Activity.StartedAt = null; Activity.TurnId = null; } Activity.WaitingStartedAt = at; }
        Activity.Phase = Phase.Waiting; Activity.Detail = detail;
    }
    private void Finish(Phase phase, string detail)
    { Activity.Phase = phase; Activity.Detail = detail; Activity.WaitingStartedAt = null; synchronous.Clear(); asynchronous.Clear(); anonymousWait = false; }
    public bool RecoverTiming(Activity recovered)
    {
        if (Activity.StartedAt != null || !Activity.Phase.IsActive() || Activity.Phase != recovered.Phase || Activity.LastEventAt is not { } last || last != recovered.LastEventAt ||
            recovered.StartedAt is not { } start || start > last || Activity.TurnId is { } current && current != recovered.TurnId || Activity.WaitingStartedAt is { } wait && start > wait) return false;
        Activity.StartedAt = start; Activity.TurnId ??= recovered.TurnId; return true;
    }
}
