using System.Windows.Threading;
using CodexTop.Core;

namespace CodexTop.Windows;

public sealed class MonitorStore : IDisposable
{
    private readonly Dispatcher dispatcher;
    private readonly PreferencesFile settingsFile;
    private readonly DispatcherTimer timer;
    private readonly DispatcherTimer debounce = new();
    private CancellationTokenSource lifetime = new();
    private LocalCodexSource source;
    private AccountUsageClient usage = new();
    private readonly Dictionary<string, FileSystemWatcher> watchers = new(StringComparer.OrdinalIgnoreCase);
    private HashSet<string> watchedPaths = new(StringComparer.OrdinalIgnoreCase);
    private string watcherKey = "";
    private bool busy, queued, disposed;
    private int generation;
    public Preferences Preferences { get; }
    public IReadOnlyList<CodexTask> Tasks { get; private set; } = [];
    public TaskGraph Graph { get; private set; } = new([]);
    public IReadOnlyList<TaskRow> Rows => Graph.Selected(Preferences);
    public bool Paused { get; private set; }
    public bool Loading { get; private set; } = true;
    public string? Error { get; private set; }
    public string? Notice { get; set; }
    public QuotaSnapshot? Quota => usage.Current;
    public string? QuotaError => usage.Error;
    public string Root => source.Root;
    public event Action? Changed;
    public MonitorStore(Dispatcher dispatcher, string? testRoot = null)
    {
        this.dispatcher = dispatcher;
        var preferencesPath = testRoot == null ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexTop", "settings.json") : Path.Combine(testRoot, "settings.json");
        settingsFile = new(preferencesPath);
        try { Preferences = settingsFile.Load(); }
        catch (Exception e) when (e is IOException or System.Text.Json.JsonException or UnauthorizedAccessException)
        { Preferences = new(); Notice = "设置文件无法读取，本次使用默认设置。"; }
        source = new(Preferences.CodexHome ?? LocalCodexSource.DefaultRoot);
        timer = new(TimeSpan.FromSeconds(2), DispatcherPriority.Background, (_, _) => { if (!Paused) RequestRefresh(); _ = RefreshQuotaAsync(false); }, dispatcher);
        debounce.Interval = TimeSpan.FromMilliseconds(200);
        debounce.Tick += (_, _) => { debounce.Stop(); RequestRefresh(); };
    }
    public void Start() { RequestRefresh(); _ = RefreshQuotaAsync(false); }
    public void Notify() => Changed?.Invoke();
    public void Save()
    {
        try { settingsFile.Save(Preferences); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Notice = "设置暂时无法保存，请检查目录权限。"; }
        Notify();
    }
    public void SetPaused(bool paused)
    {
        Paused = paused;
        if (paused) ClearWatchers(); else RequestRefresh();
        Notify();
    }
    public void ChangeSource(string root, string? cli)
    {
        generation++; lifetime.Cancel(); lifetime.Dispose(); lifetime = new();
        ClearWatchers(); source = new(root); usage = new();
        Preferences.CodexHome = source.Root; Preferences.CliPath = cli;
        Preferences.Initialized = false; Preferences.BaselineIds.Clear();
        Tasks = []; Graph = new([]); Error = null; Loading = true; Save();
        RequestRefresh(); _ = RefreshQuotaAsync(true);
    }
    public void RequestRefresh()
    {
        if (disposed || Paused) return;
        if (busy) { queued = true; return; }
        _ = RefreshAsync();
    }
    private async Task RefreshAsync()
    {
        busy = true; int version = generation;
        var selected = Preferences.SelectedIds.ToHashSet(); var reader = source; var token = lifetime.Token;
        try
        {
            var snapshot = await Task.Run(() => reader.Snapshot(selected, token), token);
            if (disposed || version != generation || Paused) return;
            Tasks = snapshot.Tasks; Graph = new(Tasks); Error = snapshot.Warning;
            if (MonitoringPolicy.Reconcile(Preferences, Tasks, Graph, snapshot.ObservedAt)) Save();
            UpdateWatchers();
        }
        catch (OperationCanceledException) { }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            if (version == generation) { Error = e.Message; Tasks = []; Graph = new([]); ClearWatchers(); }
        }
        finally
        {
            if (version == generation) Loading = false;
            busy = false;
            if (!disposed) { Notify(); if (queued) { queued = false; RequestRefresh(); } }
        }
    }
    public async Task RefreshQuotaAsync(bool force)
    {
        if (disposed) return;
        var client = usage; int version = generation; var before = client.Current; var beforeError = client.Error;
        try { await client.RefreshAsync(Root, Preferences.CliPath, force, lifetime.Token); }
        catch (OperationCanceledException) { return; }
        if (!disposed && version == generation && (before != client.Current || beforeError != client.Error)) Notify();
    }
    private void UpdateWatchers()
    {
        var paths = Rows.Where(r => r.Activity.Phase == Phase.Waiting).Select(r => r.Source.RolloutPath).Distinct(StringComparer.OrdinalIgnoreCase).Take(64).Order(StringComparer.OrdinalIgnoreCase).ToList();
        string key = string.Join('\n', paths);
        if (key == watcherKey) return;
        ClearWatchers(); watcherKey = key; watchedPaths = paths.ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var directory in paths.Select(Path.GetDirectoryName).OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                var watcher = new FileSystemWatcher(directory) { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName };
                int version = generation;
                FileSystemEventHandler change = (_, e) => dispatcher.BeginInvoke(() => { if (!disposed && !Paused && version == generation && watchedPaths.Contains(e.FullPath)) { debounce.Stop(); debounce.Start(); } });
                watcher.Changed += change; watcher.Created += change; watcher.Deleted += change;
                watcher.Renamed += (_, e) => change(watcher, e);
                watcher.Error += (_, _) => dispatcher.BeginInvoke(() => { if (version == generation) { watcherKey = ""; RequestRefresh(); } });
                watcher.EnableRaisingEvents = true; watchers[directory] = watcher;
            }
            catch (Exception e) when (e is IOException or ArgumentException or UnauthorizedAccessException) { }
        }
    }
    private void ClearWatchers()
    { debounce.Stop(); foreach (var watcher in watchers.Values) watcher.Dispose(); watchers.Clear(); watchedPaths.Clear(); watcherKey = ""; }
    public void Dispose()
    { if (disposed) return; disposed = true; timer.Stop(); ClearWatchers(); lifetime.Cancel(); lifetime.Dispose(); }
}
