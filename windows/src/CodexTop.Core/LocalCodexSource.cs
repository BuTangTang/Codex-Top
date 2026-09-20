using System.Globalization;
using System.Text.Json;

namespace CodexTop.Core;

public sealed class LocalCodexSource(string root)
{
    public string Root { get; } = Path.GetFullPath(root);
    private readonly Dictionary<string, IncrementalRollout> readers = [];
    private int recoveryCursor;
    public static string DefaultRoot => Environment.GetEnvironmentVariable("CODEX_HOME") is { Length: > 0 } path ? path : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
    public SourceSnapshot Snapshot(HashSet<string> selected, CancellationToken cancel = default)
    {
        if (!Directory.Exists(Root)) throw new DirectoryNotFoundException("未找到 Codex 数据目录，请在设置中选择。");
        var database = Directory.EnumerateFiles(Root, "state_*.sqlite").Select(path => new { Path = path, Version = int.TryParse(Path.GetFileNameWithoutExtension(path).AsSpan(6), out int version) ? version : -1 })
            .Where(v => v.Version >= 0).OrderByDescending(v => v.Version).FirstOrDefault()?.Path;
        if (database is null) throw new FileNotFoundException("未找到 Codex 任务数据库，请先在 Codex 中创建任务或选择数据目录。");
        using var db = new NativeSqlite(database);
        var columns = db.Query("PRAGMA table_info(threads)").Select(row => row["name"]).ToHashSet();
        if (new[] { "id", "title", "cwd", "rollout_path", "created_at", "updated_at", "archived" }.Any(name => !columns.Contains(name))) throw new InvalidDataException("当前 Codex 数据格式不受支持，请更新 Codex Top。");
        string title = columns.Contains("name") ? "COALESCE(NULLIF(name,''),title)" : "title";
        string created = columns.Contains("created_at_ms") ? "COALESCE(created_at_ms,created_at*1000)" : "created_at*1000";
        string updated = columns.Contains("updated_at_ms") ? "COALESCE(updated_at_ms,updated_at*1000)" : "updated_at*1000";
        var records = db.Query($"SELECT id,{title} AS title,cwd,rollout_path,{created} AS created_ms,{updated} AS updated_ms,{(columns.Contains("source") ? "source" : "'' AS source")} FROM threads WHERE archived=0 ORDER BY updated_at DESC");
        var parents = new Dictionary<string, string>();
        if (db.Query("SELECT name FROM sqlite_master WHERE type='table'").Any(row => row["name"] == "thread_spawn_edges"))
            foreach (var edge in db.Query("SELECT parent_thread_id,child_thread_id FROM thread_spawn_edges"))
                if (edge["child_thread_id"] is { } child && edge["parent_thread_id"] is { } parent) parents[child] = parent;
        var tasks = new List<CodexTask>(); long bytes = 0; int failures = 0; var now = DateTimeOffset.UtcNow;
        foreach (var row in records)
        {
            cancel.ThrowIfCancellationRequested();
            if (row["id"] is not { } id || row["rollout_path"] is not { } path) continue;
            var activity = new Activity();
            try
            {
                path = Path.GetFullPath(path);
                if (!IsInsideRoot(path)) throw new IOException("记录位于数据目录之外，未读取");
                if (!readers.TryGetValue(id, out var reader)) readers[id] = reader = new();
                bytes += reader.Refresh(path);
                activity = reader.CaughtUp ? reader.Reducer.Activity.Effective(now) : reader.Reducer.Activity with { Phase = Phase.Unknown, Detail = "正在同步任务活动…" };
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
            { activity.Detail = "任务记录暂时不可读"; failures++; }
            var project = Path.GetFileName((row["cwd"] ?? "").TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            tasks.Add(new(id, CleanTitle(row["title"]), project, Timestamp(row["created_ms"]), Timestamp(row["updated_ms"]), parents.GetValueOrDefault(id) ?? ParentFromSource(row["source"]), path, activity));
        }
        var graph = new TaskGraph(tasks);
        var candidates = tasks.Where(t => selected.Contains(graph.RootIds[t.Id]) && t.Activity.Phase.IsActive() && t.Activity.StartedAt == null && readers.ContainsKey(t.Id)).ToList();
        int remaining = 8 * 1024 * 1024;
        for (int i = 0; i < candidates.Count && remaining > 0; i++)
        {
            cancel.ThrowIfCancellationRequested();
            var task = candidates[(recoveryCursor + i) % candidates.Count];
            try
            {
                var used = readers[task.Id].RecoverTiming(task.RolloutPath, Math.Min(IncrementalRollout.ScanBudget, remaining));
                bytes += used; remaining -= (int)used;
                tasks[tasks.IndexOf(task)] = task with { Activity = readers[task.Id].Reducer.Activity.Effective(now) };
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        if (candidates.Count > 0) recoveryCursor = (recoveryCursor + 1) % candidates.Count;
        var alive = tasks.Select(t => t.Id).ToHashSet();
        foreach (var id in readers.Keys.Where(id => !alive.Contains(id)).ToArray()) readers.Remove(id);
        return new(tasks, bytes, now, failures == 0 ? null : $"{failures} 个任务的记录不可用，状态显示为未知。");
    }
    private bool IsInsideRoot(string path)
    {
        var relative = Path.GetRelativePath(Root, path);
        if (Path.IsPathRooted(relative) || relative == ".." || relative.StartsWith(".." + Path.DirectorySeparatorChar)) return false;
        // Resolve each junction/symlink so an apparent child cannot escape the selected root.
        var resolved = Path.GetFullPath(new DirectoryInfo(Root).ResolveLinkTarget(true)?.FullName ?? Root);
        var current = Root;
        foreach (var part in relative.Split(Path.DirectorySeparatorChar))
        {
            current = Path.Combine(current, part);
            FileSystemInfo entry = Directory.Exists(current) ? new DirectoryInfo(current) : new FileInfo(current);
            var target = entry.ResolveLinkTarget(true);
            if (target != null) current = target.FullName;
        }
        var finalRelative = Path.GetRelativePath(resolved, current);
        return !Path.IsPathRooted(finalRelative) && finalRelative != ".." && !finalRelative.StartsWith(".." + Path.DirectorySeparatorChar);
    }
    private static DateTimeOffset Timestamp(string? value) => long.TryParse(value, out var ms) && ms >= 0 && ms <= 253402300799999 ? DateTimeOffset.FromUnixTimeMilliseconds(ms) : DateTimeOffset.UnixEpoch;
    private static string CleanTitle(string? title) => string.IsNullOrWhiteSpace(title) ? "未命名任务" : string.Concat(title.Where(c => !char.IsControl(c))).Trim();
    private static string? ParentFromSource(string? source)
    {
        if (string.IsNullOrEmpty(source) || !source.StartsWith('{')) return null;
        try { using var json = JsonDocument.Parse(source); return json.RootElement.Field("subagent").Field("thread_spawn").Text("parent_thread_id"); }
        catch (JsonException) { return null; }
    }
}
