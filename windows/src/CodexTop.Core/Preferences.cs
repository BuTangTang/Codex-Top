using System.Text.Json;

namespace CodexTop.Core;

public sealed class Preferences
{
    public HashSet<string> SelectedIds { get; set; } = [];
    public HashSet<string> ExcludedIds { get; set; } = [];
    public HashSet<string> BaselineIds { get; set; } = [];
    public bool Initialized { get; set; }
    public bool AutoMonitor { get; set; } = true;
    public DateTimeOffset AutoEnabledAt { get; set; } = DateTimeOffset.UtcNow;
    public string? CodexHome { get; set; }
    public string? CliPath { get; set; }
    public bool Dark { get; set; } = true;
    public Placement Placement { get; set; } = Placement.Orb;
    public Placement ReturnPlacement { get; set; } = Placement.Orb;
    public double Scale { get; set; } = 1;
    public int VisibleTasks { get; set; } = 4;
    public double? X { get; set; }
    public double? Y { get; set; }
    public bool ReduceMotion { get; set; }
    public void SetPlacement(Placement next)
    {
        if (next == Placement.Floating && Placement != Placement.Floating) ReturnPlacement = Placement;
        Placement = next;
    }
    public void Normalize()
    {
        Scale = NormalizeScale(Scale);
        VisibleTasks = Math.Clamp(VisibleTasks, 1, 12);
        SelectedIds ??= []; ExcludedIds ??= []; BaselineIds ??= [];
        if (!Enum.IsDefined(Placement)) Placement = Placement.Orb;
        if (!Enum.IsDefined(ReturnPlacement) || ReturnPlacement == Placement.Floating) ReturnPlacement = Placement.Top;
        if (X is { } x && !double.IsFinite(x)) X = null;
        if (Y is { } y && !double.IsFinite(y)) Y = null;
    }
    public static double NormalizeScale(double scale) => !double.IsFinite(scale) ? 1 : Math.Round(Math.Clamp(scale, .6, 1.2) * 20, MidpointRounding.AwayFromZero) / 20;
}

public sealed class TaskGraph
{
    public Dictionary<string, string> RootIds { get; } = [];
    public IReadOnlyList<CodexTask> Roots { get; }
    private readonly Dictionary<string, List<CodexTask>> children = [];
    public TaskGraph(IReadOnlyList<CodexTask> tasks)
    {
        var lookup = tasks.DistinctBy(t => t.Id).ToDictionary(t => t.Id);
        foreach (var task in tasks)
        {
            string current = task.Id;
            var path = new List<string>(); var positions = new Dictionary<string, int>();
            while (!RootIds.ContainsKey(current) && !positions.ContainsKey(current))
            {
                positions[current] = path.Count; path.Add(current);
                if (!lookup.TryGetValue(current, out var item) || item.ParentId is not { } parent || !lookup.ContainsKey(parent)) break;
                current = parent;
            }
            var root = RootIds.GetValueOrDefault(current);
            root ??= positions.TryGetValue(current, out var index) ? path.Skip(index).Min(StringComparer.Ordinal)! : current;
            foreach (var id in path) RootIds[id] = root;
        }
        Roots = lookup.Values.Where(t => RootIds[t.Id] == t.Id).ToList();
        foreach (var task in lookup.Values.Where(t => RootIds[t.Id] != t.Id))
        {
            if (!children.TryGetValue(RootIds[task.Id], out var group)) children[RootIds[task.Id]] = group = [];
            group.Add(task);
        }
    }
    public TaskRow Row(CodexTask root)
    {
        var source = children.GetValueOrDefault(root.Id)?.Where(t => t.Activity.Phase.IsActive() || t.Activity.Phase == Phase.Failed)
            .OrderBy(t => t.Activity.Phase).ThenByDescending(t => t.Activity.LastEventAt).FirstOrDefault();
        return new(root, source is not null && source.Activity.Phase < root.Activity.Phase ? source : root);
    }
    public IReadOnlyList<TaskRow> Selected(Preferences p) => Roots.Where(t => p.SelectedIds.Contains(t.Id)).Select(Row)
        .OrderBy(t => t.Activity.Phase).ThenByDescending(t => t.Activity.LastEventAt ?? t.Root.UpdatedAt).ToList();
}

public static class MonitoringPolicy
{
    public static bool Reconcile(Preferences p, IReadOnlyList<CodexTask> tasks, TaskGraph graph, DateTimeOffset now)
    {
        bool changed = false;
        if (!p.Initialized)
        {
            p.AutoEnabledAt = now; p.BaselineIds = tasks.Select(t => t.Id).ToHashSet(); p.Initialized = true; changed = true;
            foreach (var task in tasks.Where(t => t.Activity.Phase.IsActive()))
            {
                var root = graph.RootIds[task.Id];
                if (!p.ExcludedIds.Contains(root)) changed |= p.SelectedIds.Add(root);
            }
        }
        if (!p.AutoMonitor) return changed;
        var boundary = DateTimeOffset.FromUnixTimeSeconds(p.AutoEnabledAt.ToUnixTimeSeconds());
        foreach (var task in tasks.Where(t => t.CreatedAt >= boundary && !p.BaselineIds.Contains(t.Id) &&
            (t.Activity.StartedAt != null || t.Activity.Phase.IsActive() || t.Activity.Phase.IsFinished() || t.Activity.Phase == Phase.Failed)))
        {
            var root = graph.RootIds[task.Id];
            if (!p.ExcludedIds.Contains(root)) changed |= p.SelectedIds.Add(root);
        }
        return changed;
    }
    public static void ApplySelection(Preferences p, HashSet<string> original, HashSet<string> draft)
    {
        var removed = original.Except(draft).ToList(); var added = draft.Except(original).ToList();
        p.SelectedIds.ExceptWith(removed); p.SelectedIds.UnionWith(added);
        p.ExcludedIds.UnionWith(removed); p.ExcludedIds.ExceptWith(added);
    }
    public static void SetAuto(Preferences p, bool enabled, IReadOnlyList<CodexTask> tasks)
    {
        if (enabled && !p.AutoMonitor) { p.AutoEnabledAt = DateTimeOffset.UtcNow; p.BaselineIds = tasks.Select(t => t.Id).ToHashSet(); }
        p.AutoMonitor = enabled;
    }
}

public sealed class PreferencesFile(string path)
{
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
    public Preferences Load()
    {
        if (!File.Exists(path)) return new();
        var value = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(path)) ?? throw new InvalidDataException("设置文件为空");
        value.Normalize(); return value;
    }
    public void Save(Preferences value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(value, Options));
        File.Move(temporary, path, true);
    }
}
