using CodexTop.Core;
using System.Windows.Automation;

namespace CodexTop.Windows;

internal sealed class TaskPickerWindow : Window
{
    private readonly MonitorStore store;
    private readonly HashSet<string> original, draft;
    private readonly TextBox search = new() { MinHeight = 36, Margin = new(0, 0, 0, 10) };
    private readonly StackPanel list = new();
    private readonly TextBlock count;
    private bool appliedDark;
    public TaskPickerWindow(MonitorStore store)
    {
        this.store = store; original = store.Preferences.SelectedIds.ToHashSet(); draft = original.ToHashSet();
        ShowInTaskbar = false;
        StateChanged += (_, _) => { if (WindowState == WindowState.Minimized) Hide(); };
        Title = "选择任务 · Codex Top"; Width = 510; Height = 550; MinWidth = 400; MinHeight = 350; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        bool dark = store.Preferences.Dark; appliedDark = dark; Ui.ApplyWindowTheme(this, dark);
        var root = new DockPanel { Margin = new(22) };
        var header = new StackPanel();
        var heading = Ui.Text("选择关注的任务", 21, dark); heading.FontWeight = FontWeights.SemiBold; header.Children.Add(heading);
        var caption = Ui.Text("四种显示方式共用这份列表", 12, dark, true); caption.Margin = new(0, 6, 0, 16); header.Children.Add(caption);
        search.ToolTip = "搜索任务名称或项目"; AutomationProperties.SetName(search, "搜索任务名称或项目"); header.Children.Add(search);
        var bar = new DockPanel { Margin = new(0, 0, 0, 8) };
        var all = Ui.Button("全选 / 取消当前结果", "全选或取消当前搜索结果", dark, () =>
        {
            var visible = Visible().Select(t => t.Id).ToHashSet();
            if (visible.IsSubsetOf(draft)) draft.ExceptWith(visible); else draft.UnionWith(visible);
            Render();
        }); DockPanel.SetDock(all, Dock.Right); bar.Children.Add(all); count = Ui.Text("", 12, dark, true); bar.Children.Add(count); header.Children.Add(bar);
        DockPanel.SetDock(header, Dock.Top); root.Children.Add(header);
        var footer = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new(0, 14, 0, 0) };
        footer.Children.Add(Ui.Button("取消", "取消选择", dark, Close, 80));
        var apply = Ui.Button("应用选择", "应用选择", dark, () => { MonitoringPolicy.ApplySelection(store.Preferences, original, draft); store.Save(); Close(); }, 100); apply.Background = Ui.Blue; apply.Foreground = Brushes.White; footer.Children.Add(apply);
        DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
        root.Children.Add(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }); Content = root;
        search.TextChanged += (_, _) => Render(); Loaded += (_, _) => search.Focus();
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
        store.Changed += SyncFromStore; Closed += (_, _) => store.Changed -= SyncFromStore;
        Render();
    }
    private void SyncFromStore()
    {
        bool themeChanged = appliedDark != store.Preferences.Dark;
        bool selectionChanged = !original.SetEquals(store.Preferences.SelectedIds);
        if (!themeChanged && !selectionChanged) return;
        if (selectionChanged)
        {
            // Accept changes from the row buttons/auto-monitoring while preserving
            // the user's uncommitted additions and removals in this picker.
            var added = draft.Except(original).ToArray(); var removed = original.Except(draft).ToArray();
            original.Clear(); original.UnionWith(store.Preferences.SelectedIds);
            draft.Clear(); draft.UnionWith(original); draft.ExceptWith(removed); draft.UnionWith(added);
        }
        if (themeChanged) { appliedDark = store.Preferences.Dark; Ui.ApplyWindowTheme(this, appliedDark); }
        Render();
    }
    private IEnumerable<CodexTask> Visible() => store.Graph.Roots.Where(t => t.Title.Contains(search.Text.Trim(), StringComparison.OrdinalIgnoreCase) || t.Project.Contains(search.Text.Trim(), StringComparison.OrdinalIgnoreCase)).OrderByDescending(t => t.UpdatedAt);
    private void Render()
    {
        list.Children.Clear(); bool dark = store.Preferences.Dark; count.Text = $"已选择 {draft.Count} 项";
        foreach (var task in Visible())
        {
            var content = new StackPanel { Margin = new(5, 0, 0, 0) };
            content.Children.Add(Ui.Text(task.Title, 14, dark)); content.Children.Add(Ui.Text(task.Project + " · " + store.Graph.Row(task).Activity.Phase.Label(), 11, dark, true));
            var check = new CheckBox { Content = content, IsChecked = draft.Contains(task.Id), Padding = new(4, 9, 4, 9), HorizontalContentAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(check, task.Title);
            check.Checked += (_, _) => { draft.Add(task.Id); count.Text = $"已选择 {draft.Count} 项"; };
            check.Unchecked += (_, _) => { draft.Remove(task.Id); count.Text = $"已选择 {draft.Count} 项"; }; list.Children.Add(check);
        }
        if (list.Children.Count == 0) list.Children.Add(Ui.Text("没有匹配的本地任务", 14, dark, true));
    }
}

internal sealed class SettingsWindow : Window
{
    private readonly MonitorStore store;
    private readonly Slider scale;
    private readonly TextBlock scaleLabel, status;
    private readonly ComboBox theme;
    private bool syncing;
    public SettingsWindow(MonitorStore store)
    {
        this.store = store; bool dark = store.Preferences.Dark;
        ShowInTaskbar = false;
        StateChanged += (_, _) => { if (WindowState == WindowState.Minimized) Hide(); };
        Title = "监控设置 · Codex Top"; Width = 480; Height = 640; MinWidth = 420; MinHeight = 400; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Ui.ApplyWindowTheme(this, dark);
        var panel = new StackPanel { Margin = new(26, 20, 26, 22) }; Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        void Heading(string text) { var label = Ui.Text(text, 15, dark); label.FontWeight = FontWeights.SemiBold; label.Margin = new(0, 18, 0, 10); panel.Children.Add(label); }
        void Description(string text) { var t = Ui.Text(text, 11, dark, true); t.TextWrapping = TextWrapping.Wrap; t.Margin = new(0, 6, 0, 4); panel.Children.Add(t); }
        panel.Children.Add(Ui.Text("监控设置", 23, dark));
        Heading("显示位置");
        var placement = new ComboBox { ItemsSource = Enum.GetValues<Placement>().Select(p => new { Id = p, Label = MonitorWindow.PlacementName(p) }).ToArray(), DisplayMemberPath = "Label", SelectedValuePath = "Id", SelectedValue = store.Preferences.Placement, MinHeight = 34 };
        AutomationProperties.SetName(placement, "显示位置"); placement.SelectionChanged += (_, _) => { if (placement.SelectedValue is Placement p) { store.Preferences.SetPlacement(p); store.Save(); } }; panel.Children.Add(placement);
        Heading("外观");
        theme = new ComboBox { ItemsSource = new[] { "深色", "浅色" }, SelectedIndex = dark ? 0 : 1, MinHeight = 34 };
        theme.SelectionChanged += (_, _) => { if (!syncing) { store.Preferences.Dark = theme.SelectedIndex == 0; store.Save(); } }; AutomationProperties.SetName(theme, "主题"); panel.Children.Add(theme);
        var scaleRow = new DockPanel { Margin = new(0, 12, 0, 0) };
        var reset = Ui.Button("恢复 100%", "恢复默认显示比例", dark, () => { store.Preferences.Scale = 1; store.Save(); }); DockPanel.SetDock(reset, Dock.Right); scaleRow.Children.Add(reset);
        scaleLabel = Ui.Text("", 12, dark); scaleRow.Children.Add(scaleLabel); panel.Children.Add(scaleRow);
        scale = new Slider { Minimum = 60, Maximum = 120, TickFrequency = 5, IsSnapToTickEnabled = true, Value = store.Preferences.Scale * 100, Margin = new(0, 6, 0, 6) };
        AutomationProperties.SetName(scale, "显示比例"); scale.ValueChanged += (_, _) => { if (!syncing) { store.Preferences.Scale = Preferences.NormalizeScale(scale.Value / 100); store.Save(); } }; panel.Children.Add(scale);
        Description("Ctrl + 加号 / 减号调整比例。桌面圆环常态为 44 DIP，悬停时轻柔放大。");
        var motion = new CheckBox { Content = "减少动态效果", IsChecked = store.Preferences.ReduceMotion, Margin = new(0, 7, 0, 0) };
        motion.Click += (_, _) => { store.Preferences.ReduceMotion = motion.IsChecked == true; store.Save(); }; panel.Children.Add(motion);
        Heading("任务");
        var visible = new ComboBox { ItemsSource = Enumerable.Range(1, 12).ToArray(), SelectedItem = store.Preferences.VisibleTasks, MinHeight = 32 };
        visible.SelectionChanged += (_, _) => { if (visible.SelectedItem is int value) { store.Preferences.VisibleTasks = value; store.Save(); } }; AutomationProperties.SetName(visible, "可见任务数"); panel.Children.Add(visible);
        Description("可见任务数，超出后滚动查看。");
        var automatic = new CheckBox { Content = "自动关注新建并开始的任务", IsChecked = store.Preferences.AutoMonitor, Margin = new(0, 8, 0, 0) };
        automatic.Click += (_, _) => { MonitoringPolicy.SetAuto(store.Preferences, automatic.IsChecked == true, store.Tasks); store.Save(); }; panel.Children.Add(automatic);
        Heading("账户额度");
        status = Ui.Text("", 11, dark, true); status.TextWrapping = TextWrapping.Wrap; panel.Children.Add(status);
        panel.Children.Add(Ui.Button("刷新账户额度", "刷新账户额度", dark, () => _ = store.RefreshQuotaAsync(true)));
        Heading("数据来源");
        if (store.Error is { } sourceWarning) Description(sourceWarning);
        var root = new TextBox { Text = store.Root, IsReadOnly = true, MinHeight = 34 }; AutomationProperties.SetName(root, "Codex 数据目录"); panel.Children.Add(root);
        panel.Children.Add(Ui.Button("选择数据目录…", "选择 Codex 数据目录", dark, () =>
        {
            var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "选择包含 state_*.sqlite 的 Codex 数据目录", InitialDirectory = store.Root };
            if (dialog.ShowDialog(this) == true) { store.ChangeSource(dialog.FolderName, store.Preferences.CliPath); root.Text = store.Root; }
        }));
        panel.Children.Add(Ui.Button("选择 Codex CLI…", "选择 Codex CLI 可执行文件", dark, () =>
        {
            var dialog = new Microsoft.Win32.OpenFileDialog { Title = "选择官方 Codex CLI", Filter = "Codex CLI (codex.exe)|codex.exe", CheckFileExists = true };
            if (dialog.ShowDialog(this) == true) store.ChangeSource(store.Root, dialog.FileName);
        }));
        Description("本地任务只读。登录状态由 Codex CLI 管理。额度约每 60 秒刷新，任务约每 2 秒刷新。");
        Heading("关于"); Description("Codex Top for Windows 0.1.8\n基于 BuTangTang/Codex-Top · GPL-3.0\n独立社区项目，与 OpenAI 没有官方关联。");
        store.Changed += Sync; Closed += (_, _) => store.Changed -= Sync; Sync();
    }
    private void Sync()
    {
        syncing = true; Ui.ApplyWindowTheme(this, store.Preferences.Dark); theme.SelectedIndex = store.Preferences.Dark ? 0 : 1;
        scale.Value = store.Preferences.Scale * 100; scaleLabel.Text = $"显示比例   {scale.Value:0}%";
        status.Text = store.Quota is { } quota ? "当前账户 · 更新于 " + quota.ObservedAt.ToLocalTime().ToString("HH:mm:ss") : store.QuotaError ?? "正在读取账户额度…"; syncing = false;
    }
}
