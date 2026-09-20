using System.ComponentModel;
using System.Diagnostics;
using System.Windows.Automation;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CodexTop.Core;
using Activity = CodexTop.Core.Activity;

namespace CodexTop.Windows;

public sealed class MonitorWindow : Window
{
    private readonly MonitorStore store;
    private readonly Grid canvas = new();
    private readonly Border shell = new();
    private const double OrbSize = 44, OrbPadding = 6, OrbHostSize = OrbSize + OrbPadding * 2;
    private readonly ScaleTransform orbHover = new(1, 1);
    private readonly DispatcherTimer clock;
    private readonly DispatcherTimer hoverClose = new();
    private readonly DispatcherTimer dismissCheck = new();
    private readonly List<(TextBlock Label, Activity Activity)> timers = [];
    private bool expanded, upward, dragging, menuOpen, renderQueued, closing, dismissRequestedByMenu;
    private int animationVersion;
    private double anchorX, anchorY;
    private Point? dragStart;
    private bool moved;
    private bool dpiRefreshQueued;
    private Window? picker, settings;
    internal ContextMenu? ActiveMenu { get; private set; }
    private Placement appliedPlacement;
    private System.Windows.Forms.NotifyIcon? tray;
    private readonly bool reducedBySystem;
    private readonly string title;
    private string displayKey = "";
    private readonly bool qaWindow;
    private bool Animate => !store.Preferences.ReduceMotion && !reducedBySystem;
    private bool IsOrb => store.Preferences.Placement == Placement.Orb && !expanded;
    public MonitorWindow(MonitorStore store, bool qaWindow = false)
    {
        this.store = store; this.qaWindow = qaWindow; title = "Codex Top"; Title = title;
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent; ShowInTaskbar = false;
        Topmost = true; Width = Height = 44; FontFamily = new("Microsoft YaHei UI");
        UseLayoutRounding = true; SnapsToDevicePixels = true;
        Content = canvas; canvas.Children.Add(shell); shell.HorizontalAlignment = HorizontalAlignment.Left; shell.VerticalAlignment = VerticalAlignment.Top;
        reducedBySystem = !SystemParameters.ClientAreaAnimation;
        appliedPlacement = store.Preferences.Placement;
        expanded = appliedPlacement == Placement.Floating;
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            if (HwndSource.FromHwnd(handle) is { } source) source.CompositionTarget.BackgroundColor = Colors.Transparent;
            NativeWindow.Style(this, store.Preferences.Dark);
        };
        Loaded += (_, _) => { PlaceInitially(); InitializeTray(); Render(false); store.Start(); };
        Deactivated += (_, _) => { if (menuOpen) dismissRequestedByMenu = true; QueueDismissIfOutside(); };
        PreviewMouseDown += (_, _) => dismissRequestedByMenu = false;
        MouseEnter += (_, _) => { hoverClose.Stop(); UpdateOrbHover(true); if (store.Preferences.Placement == Placement.Top && !expanded) Expand(); };
        MouseLeave += (_, _) => { UpdateOrbHover(false); if (store.Preferences.Placement == Placement.Top) hoverClose.Start(); };
        MouseRightButtonUp += (_, e) => { OpenMenu(); e.Handled = true; };
        PreviewKeyDown += OnKey;
        StateChanged += (_, _) =>
        {
            if (WindowState != WindowState.Minimized) return;
            WindowState = WindowState.Normal; MinimizeToTray();
        };
        store.Changed += OnStoreChanged;
        clock = new(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => UpdateTimers(), Dispatcher);
        hoverClose.Interval = TimeSpan.FromMilliseconds(250);
        hoverClose.Tick += (_, _) => { hoverClose.Stop(); if (!IsMouseOver && !menuOpen && picker?.IsVisible != true && settings?.IsVisible != true && store.Preferences.Placement == Placement.Top) Collapse(); };
        dismissCheck.Interval = TimeSpan.FromMilliseconds(80);
        dismissCheck.Tick += (_, _) =>
        {
            dismissCheck.Stop();
            // Native focus can still be changing inside a Show/Activate message
            // loop. Wait briefly, then use the final owner chain, not stale state.
            if (closing || menuOpen || dragging || !expanded || store.Preferences.Placement is not (Placement.Orb or Placement.Tray)) return;
            bool menuDismiss = dismissRequestedByMenu; dismissRequestedByMenu = false;
            // WPF can restore the owner's focus when a menu closes. Preserve the
            // outside-click/deactivation intent, unless a menu command or a new
            // click in the tool superseded it. Dialog interactions remain internal.
            if (menuDismiss ? !NativeWindow.IsForegroundWithin(picker, settings) : !NativeWindow.IsForegroundWithin(this, picker, settings)) Collapse();
        };
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += DisplayChanged;
    }
    private void QueueDismissIfOutside()
    {
        if (closing) return;
        dismissCheck.Stop(); dismissCheck.Start();
    }
    private void ObserveDialog(Window dialog)
    {
        dialog.Deactivated += (_, _) => QueueDismissIfOutside();
        dialog.IsVisibleChanged += (_, _) => QueueDismissIfOutside();
        dialog.Closed += (_, _) => QueueDismissIfOutside();
    }
    private void PlaceInitially()
    {
        var screen = System.Windows.Forms.Screen.PrimaryScreen!; var area = screen.WorkingArea;
        var dpi = VisualTreeHelper.GetDpi(this);
        anchorX = store.Preferences.X ?? (area.Right / dpi.DpiScaleX - 130);
        anchorY = store.Preferences.Y ?? (area.Top / dpi.DpiScaleY + 160);
        NativeWindow.MoveLogical(this, new(anchorX, anchorY)); NativeWindow.Clamp(this); ReadAnchor();
        if (store.Preferences.Placement == Placement.Top) { var work = NativeWindow.WorkArea(this); NativeWindow.MoveLogical(this, new(work.Left + (work.Width - 410 * store.Preferences.Scale) / 2, work.Top + 6)); }
    }
    private void InitializeTray()
    {
        tray = new() { Text = "Codex Top · 正在读取任务", Visible = true, Icon = System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!) };
        tray.MouseClick += (_, e) => Dispatcher.Invoke(() =>
        {
            if (e.Button == System.Windows.Forms.MouseButtons.Right) { if (store.Preferences.Placement == Placement.Tray && !expanded) PositionAtTray(); OpenMenu(); }
            else if (e.Button == System.Windows.Forms.MouseButtons.Left) { if (expanded && IsVisible) Collapse(); else { if (store.Preferences.Placement == Placement.Tray) PositionAtTray(); Expand(); } }
        });
    }
    private void PositionAtTray()
    {
        var cursor = System.Windows.Forms.Cursor.Position; var screen = System.Windows.Forms.Screen.FromPoint(cursor);
        // Enter the target monitor first, so subsequent DIP offsets use its DPI.
        NativeWindow.Move(this, new(screen.WorkingArea.Left + screen.WorkingArea.Width / 2, screen.WorkingArea.Top + screen.WorkingArea.Height / 2));
        var dpi = VisualTreeHelper.GetDpi(this);
        NativeWindow.MoveLogical(this, new((screen.WorkingArea.Right / dpi.DpiScaleX) - 430 * store.Preferences.Scale,
            screen.WorkingArea.Bottom / dpi.DpiScaleY - 360 * store.Preferences.Scale));
        ReadAnchor();
    }
    private void OnStoreChanged()
    {
        if (closing) return;
        if (appliedPlacement != store.Preferences.Placement)
        {
            StopAnimation(); appliedPlacement = store.Preferences.Placement;
            expanded = appliedPlacement == Placement.Floating; upward = false;
            if (appliedPlacement == Placement.Top) { var a = NativeWindow.WorkArea(this); NativeWindow.MoveLogical(this, new(a.Left + (a.Width - 410 * store.Preferences.Scale) / 2, a.Top + 6)); }
            else NativeWindow.MoveLogical(this, new(anchorX, anchorY));
        }
        if (displayKey == DisplayKey()) return;
        if (menuOpen || dragging) { renderQueued = true; return; }
        Render(false);
    }
    private string DisplayKey()
    {
        var p = store.Preferences;
        return $"{p.Placement}|{expanded}|{showFinished}|{p.Dark}|{p.Scale}|{p.VisibleTasks}|{p.ReduceMotion}|{store.Paused}|{store.Loading}|{store.Error}|{store.Notice}|{QuotaLong()}|{QuotaTooltip()}|" +
            string.Join('|', store.Rows.Select(r => $"{r.Root.Id}:{r.Root.Title}:{r.Root.Project}:{r.Source.Id}:{r.Activity.Phase}:{r.Activity.StartedAt:O}:{r.Activity.WaitingStartedAt:O}:{r.Activity.Detail}"));
    }
    private Phase Overall(IReadOnlyList<TaskRow> rows)
    {
        if (store.Paused || store.Error is not null && rows.Count == 0) return Phase.Unknown;
        if (rows.Any(r => r.Activity.Phase == Phase.Failed)) return Phase.Failed;
        if (rows.Any(r => r.Activity.Phase == Phase.Waiting)) return Phase.Waiting;
        if (rows.Any(r => r.Activity.Phase == Phase.Running)) return Phase.Running;
        return rows.Count > 0 && rows.All(r => r.Activity.Phase == Phase.Completed) ? Phase.Completed : Phase.Unknown;
    }
    private string Summary(IReadOnlyList<TaskRow> rows)
    {
        if (store.Paused) return "任务刷新已暂停";
        int waiting = rows.Count(r => r.Activity.Phase is Phase.Waiting or Phase.Failed), running = rows.Count(r => r.Activity.Phase == Phase.Running);
        if (waiting > 0) return $"{waiting} 项待处理";
        if (running > 0) return $"{running} 项运行中";
        if (store.Loading) return "正在读取任务…";
        return rows.Count == 0 ? "选择关注的任务" : rows.All(r => r.Activity.Phase.IsFinished()) ? "任务已结束" : "等待新活动";
    }
    private void Render(bool animate)
    {
        displayKey = DisplayKey();
        bool dark = store.Preferences.Dark; var rows = store.Rows; var phase = Overall(rows); double scale = store.Preferences.Scale;
        Ui.SetThemeResources(this, dark);
        timers.Clear(); shell.Child = null;
        shell.Margin = IsOrb ? new(OrbPadding) : new(0);
        shell.RenderTransformOrigin = new(.5, .5);
        shell.RenderTransform = IsOrb ? orbHover : Transform.Identity;
        if (!IsOrb || !Animate) UpdateOrbHover(false, true);
        shell.Background = dark ? Brushes.Black : Ui.Brush("#F7F7F8"); shell.BorderBrush = null; shell.BorderThickness = new(0);
        Foreground = Ui.Fore(dark);
        if (tray != null) tray.Text = $"Codex Top · {Summary(rows)}";
        if (store.Preferences.Placement == Placement.Tray && !expanded) { Hide(); return; }
        if (!IsVisible) Show();
        double width, height;
        if (IsOrb)
        {
            shell.Background = dark ? Brushes.Black : Ui.Brush("#F7F7F8");
            shell.BorderThickness = new(0); shell.BorderBrush = null;
            width = height = OrbSize; shell.CornerRadius = new(OrbSize / 2);
            var grid = new Grid(); var ring = new RunningRing(40, phase, dark, Animate) { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }; grid.Children.Add(ring);
            var number = Ui.Text(phase == Phase.Completed ? "✓" : Math.Min(rows.Count(r => r.Activity.Phase == Phase.Running), 100) is var count && count > 99 ? "99+" : count.ToString(), 15, dark);
            number.HorizontalAlignment = HorizontalAlignment.Center; number.FontWeight = FontWeights.SemiBold; grid.Children.Add(number);
            if (phase is Phase.Waiting or Phase.Failed)
            {
                shell.Background = dark ? Ui.Brush(phase == Phase.Failed ? "#241214" : "#211B10") : Ui.Brush(phase == Phase.Failed ? "#FFF0F1" : "#FFF7EF");
                var attention = Ui.Text("!", 10, dark); attention.Foreground = Ui.Status(phase, dark); attention.HorizontalAlignment = HorizontalAlignment.Right; attention.VerticalAlignment = VerticalAlignment.Top; attention.Margin = new(0, 4, 7, 0); grid.Children.Add(attention);
                if (Animate)
                {
                    // Pulse the contents separately so the hover outline and hit area stay stable.
                    var transform = new ScaleTransform(1, 1); grid.RenderTransformOrigin = new(.5, .5); grid.RenderTransform = transform;
                    var pulse = new DoubleAnimation(1, .942, TimeSpan.FromSeconds(.9)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() };
                    transform.BeginAnimation(ScaleTransform.ScaleXProperty, pulse); transform.BeginAnimation(ScaleTransform.ScaleYProperty, pulse);
                }
            }
            shell.Child = grid; shell.ToolTip = Summary(rows) + " · 点击展开，拖动移动，右键菜单";
            AutomationProperties.SetName(shell, "任务圆环，" + Summary(rows));
            shell.PreviewMouseLeftButtonDown -= OrbDown; shell.PreviewMouseLeftButtonDown += OrbDown;
            shell.PreviewMouseMove -= OrbMove; shell.PreviewMouseMove += OrbMove;
            shell.PreviewMouseLeftButtonUp -= OrbUp; shell.PreviewMouseLeftButtonUp += OrbUp;
            NativeWindow.MoveLogical(this, new(anchorX, anchorY));
        }
        else
        {
            shell.PreviewMouseLeftButtonDown -= OrbDown; shell.PreviewMouseMove -= OrbMove; shell.PreviewMouseLeftButtonUp -= OrbUp; shell.ToolTip = null;
            width = (store.Preferences.Placement == Placement.Floating ? 360 : 410) * scale;
            shell.CornerRadius = new(20 * scale);
            if (!expanded)
            {
                height = 43 * scale;
                var summary = new Grid { Margin = new(14 * scale, 0, 14 * scale, 0) };
                var left = Ui.Text(Summary(rows), Math.Max(12, 13 * scale), dark); summary.Children.Add(left);
                var right = Ui.Text(QuotaShort(), Math.Max(11, 12 * scale), dark, true); right.HorizontalAlignment = HorizontalAlignment.Right; summary.Children.Add(right);
                shell.Child = summary;
            }
            else
            {
                var panel = BuildPanel(rows, dark, scale); panel.Width = Math.Max(1, width - 2 - 30 * scale); shell.Child = panel;
                height = MeasurePanel(panel, width);
            }
        }
        // Keep the HWND transparent: WPF supplies antialiased alpha for the outline,
        // including animated sizes. An opaque underlay or GDI region loses that edge.
        Background = Brushes.Transparent;
        if (expanded && upward) NativeWindow.MoveLogical(this, new(NativeWindow.LogicalPosition(this).X, anchorY + OrbHostSize - height));
        SetSize(width, height, animate);
        RefreshNativeStyle(); if (expanded || !animate || !Animate) NativeWindow.Clamp(this);
    }
    private Grid BuildPanel(IReadOnlyList<TaskRow> rows, bool dark, double scale)
    {
        var grid = new Grid { Margin = new(15 * scale, 7 * scale, 15 * scale, 9 * scale) };
        grid.RowDefinitions.Add(new() { Height = GridLength.Auto }); grid.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) }); grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
        var header = new Grid { Height = 37 * scale, Background = Brushes.Transparent };
        header.PreviewMouseLeftButtonDown += HeaderDrag;
        var title = Ui.Text("Codex Top", Math.Max(14, 17 * scale), dark); title.FontWeight = FontWeights.SemiBold; header.Children.Add(title);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(Ui.Button("＋", "选择关注任务", dark, OpenPicker, 28 * scale));
        buttons.Children.Add(Ui.Button("⋯", "更多选项", dark, OpenMenu, 28 * scale)); header.Children.Add(buttons); grid.Children.Add(header);
        var list = new StackPanel();
        if (store.Error != null && store.Tasks.Count == 0 || store.Notice != null)
        {
            var warning = Ui.Text(store.Notice ?? store.Error!, Math.Max(11, 12 * scale), dark, true); warning.TextWrapping = TextWrapping.Wrap; warning.Margin = new(0, 4, 0, 8); list.Children.Add(warning);
        }
        if (rows.Count == 0)
        {
            var empty = new StackPanel { Margin = new(0, 18, 0, 22) };
            var prompt = Ui.Text(store.Loading ? "正在读取本地任务…" : "把关注的任务放在这里", Math.Max(13, 15 * scale), dark); empty.Children.Add(prompt);
            var subtitle = Ui.Text(store.Loading ? "稍等片刻" : "新任务开始时自动加入，也可以手动选择。", Math.Max(11, 12 * scale), dark, true); subtitle.Margin = new(0, 6, 0, 10); subtitle.TextWrapping = TextWrapping.Wrap; empty.Children.Add(subtitle);
            empty.Children.Add(Ui.Button("＋  选择任务", "选择关注任务", dark, OpenPicker)); list.Children.Add(empty);
        }
        foreach (var row in rows.Where(r => !r.Activity.Phase.IsFinished())) list.Children.Add(BuildRow(row, dark, scale));
        var finished = rows.Where(r => r.Activity.Phase.IsFinished()).ToList();
        if (finished.Count > 0)
        {
            var fold = Ui.Button($"{(showFinished ? "⌄" : "›")}  已结束 · {finished.Count}", "展开或收起已结束任务", dark, () => { showFinished = !showFinished; Render(false); }); fold.FontSize = Math.Max(11, 12 * scale); fold.HorizontalContentAlignment = HorizontalAlignment.Left; list.Children.Add(fold);
            if (showFinished) foreach (var row in finished) list.Children.Add(BuildRow(row, dark, scale));
        }
        var scroll = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, MaxHeight = store.Preferences.VisibleTasks * 62 * scale + 30 * scale, Margin = new(0, 4 * scale, 0, 8 * scale) };
        Grid.SetRow(scroll, 1); grid.Children.Add(scroll);
        var footer = new StackPanel();
        footer.Children.Add(new Border { Height = 1, Background = dark ? Ui.Brush("#252529") : Ui.Brush("#18000000"), Margin = new(0, 0, 0, 8 * scale) });
        var quota = Ui.Button(QuotaLong(), "账户剩余额度 · 点击打开官方用量页", dark, () => OpenUrl(new("https://chatgpt.com/codex/settings/usage")));
        quota.FontSize = Math.Max(11, 12 * scale); quota.ToolTip = QuotaTooltip(); footer.Children.Add(quota);
        if (store.Paused) { var paused = Ui.Text("任务刷新已暂停", 11, dark, true); paused.HorizontalAlignment = HorizontalAlignment.Center; footer.Children.Add(paused); }
        Grid.SetRow(footer, 2); grid.Children.Add(footer); return grid;
    }
    private bool showFinished;
    private FrameworkElement BuildRow(TaskRow row, bool dark, double scale)
    {
        var grid = new Grid { Margin = new(2, 6 * scale, 2, 6 * scale), MinHeight = 45 * scale };
        grid.ColumnDefinitions.Add(new() { Width = new(29 * scale) }); grid.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var ring = new RunningRing(22 * scale, row.Activity.Phase, dark, Animate) { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Left }; grid.Children.Add(ring);
        var labels = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new(0, 0, 7 * scale, 0) };
        var title = Ui.Text(row.Root.Title, Math.Max(13, (store.Preferences.Placement == Placement.Floating ? 14 : 16) * scale), dark); title.FontWeight = FontWeights.Medium; labels.Children.Add(title);
        var detail = Ui.Text((row.Source.Id != row.Root.Id ? "子任务 · " : "") + (string.IsNullOrEmpty(row.Root.Project) ? "本地任务" : row.Root.Project), Math.Max(11, 12 * scale), dark, true); detail.Margin = new(0, 4 * scale, 0, 0); labels.Children.Add(detail); Grid.SetColumn(labels, 1); grid.Children.Add(labels);
        var status = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
        var badge = new Border { CornerRadius = new(4), Padding = new(5, 2, 5, 2) };
        var label = Ui.Text(row.Activity.Phase.Label(), Math.Max(11, 12 * scale), dark);
        if (row.Activity.Phase is Phase.Waiting or Phase.Failed)
        {
            badge.Background = Ui.Brush(row.Activity.Phase == Phase.Failed ? "#20F0646B" : dark ? "#20F3B850" : "#1FE86E0F");
            if (dark || row.Activity.Phase == Phase.Failed) label.Foreground = Ui.Status(row.Activity.Phase, dark);
        }
        else if (row.Activity.Phase == Phase.Completed) label.Foreground = Ui.Green;
        badge.Child = label; status.Children.Add(badge);
        var timer = Ui.Text(row.Activity.Timer(DateTimeOffset.UtcNow), Math.Max(11, 12 * scale), dark, true); timer.FontFamily = new("Consolas"); timer.HorizontalAlignment = HorizontalAlignment.Right; timer.Margin = new(0, 3, 4, 0); status.Children.Add(timer); timers.Add((timer, row.Activity));
        Grid.SetColumn(status, 2); grid.Children.Add(status);
        var click = new Border { Child = grid, Background = Brushes.Transparent, Cursor = Cursors.Hand, CornerRadius = new(8), Focusable = true };
        click.ToolTip = $"{row.Root.Title}\n{row.Activity.Detail}\n" + (row.Activity.Phase == Phase.Running && row.Activity.StartedAt == null ? "缺少本轮开始记录，暂不估计耗时。\n" : "") + (row.Activity.Phase == Phase.Waiting ? "计时为本轮开始到等待开始的耗时；回复写入本地记录后更新。\n" : "") + "点击返回 Codex 任务";
        AutomationProperties.SetName(click, row.Root.Title + "，" + row.Activity.Phase.Label());
        click.MouseEnter += (_, _) => click.Background = dark ? Ui.Brush("#12FFFFFF") : Ui.Brush("#0A000000"); click.MouseLeave += (_, _) => click.Background = Brushes.Transparent;
        click.MouseLeftButtonUp += (_, e) => { OpenTask(row.NavigationTarget); e.Handled = true; };
        click.KeyDown += (_, e) => { if (e.Key == Key.Enter) { OpenTask(row.NavigationTarget); e.Handled = true; } };
        // Keep removal beside the navigation surface, not inside it: activating
        // this button must never bubble into the row's task-opening handler.
        var container = new Grid();
        container.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        container.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        container.Children.Add(click);
        var remove = Ui.Button("×", "取消关注", dark, () =>
        {
            MonitoringPolicy.ApplySelection(store.Preferences, [row.Root.Id], []);
            store.Save();
        }, Math.Max(24, 28 * scale));
        remove.SetResourceReference(Control.ForegroundProperty, "MutedBrush");
        remove.FontSize = 18; remove.Padding = new(0); remove.MinHeight = 26;
        remove.VerticalAlignment = VerticalAlignment.Center; remove.Margin = new(2, 0, 0, 0);
        AutomationProperties.SetName(remove, "取消关注：" + row.Root.Title);
        AutomationProperties.SetAutomationId(remove, "unfollow-" + row.Root.Id);
        Grid.SetColumn(remove, 1); container.Children.Add(remove); return container;
    }
    private double MeasurePanel(FrameworkElement panel, double width)
    {
        var area = NativeWindow.WorkArea(this);
        panel.Measure(new(Math.Max(1, width - 2), double.PositiveInfinity));
        return Math.Min(area.Height - 16, panel.DesiredSize.Height + 2);
    }
    private void UpdateTimers()
    {
        foreach (var item in timers) item.Label.Text = item.Activity.Timer(DateTimeOffset.UtcNow);
        if (qaWindow) File.WriteAllText(Path.Combine(Path.GetTempPath(), "codextop-layout.json"), System.Text.Json.JsonSerializer.Serialize(new { Width, Height, ActualWidth, ActualHeight, Left, Top, expanded, IsOrb, targetWidth, targetHeight, Native = NativeWindow.Diagnostics(this), PickerInTaskbar = picker?.ShowInTaskbar, SettingsInTaskbar = settings?.ShowInTaskbar }));
    }
    private double targetWidth, targetHeight;
    private string QuotaShort() => store.Quota is { } quota ? string.Join(" / ", quota.Windows.Select(w => $"{w.Remaining}%")) + " 剩余" : "额度 —";
    private string QuotaLong() => store.Quota is { } quota ? string.Join("    ·    ", quota.Windows.Select(w => $"{w.Label}  {w.Remaining}% 剩余")) + (quota.ObservedAt < DateTimeOffset.UtcNow.AddMinutes(-5) ? " · 已过期" : quota.Windows.Any(w => w.ResetsAt < DateTimeOffset.UtcNow) ? " · 待更新" : "") : store.QuotaError == null ? "正在读取账户额度…" : "账户额度暂时不可用";
    private string QuotaTooltip() => store.Quota is { } quota ? "来源：当前账户接口\n更新：" + quota.ObservedAt.ToLocalTime().ToString("HH:mm:ss") + "\n" + string.Join("\n", quota.Windows.Select(w => $"{w.Label}重置：{w.ResetsAt?.ToLocalTime().ToString("MM-dd HH:mm") ?? "未知"}")) : store.QuotaError ?? "正在读取账户额度";
    private void Expand()
    {
        if (expanded) { Show(); Activate(); return; }
        if (store.Preferences.Placement == Placement.Orb) ReadAnchor();
        expanded = true; upward = false;
        var area = NativeWindow.WorkArea(this);
        double expected = Math.Min(550, 145 + store.Preferences.VisibleTasks * 62) * store.Preferences.Scale;
        if (store.Preferences.Placement == Placement.Orb && area.Bottom - anchorY < expected && anchorY - area.Top > area.Bottom - anchorY) upward = true;
        Render(true); Activate();
    }
    private void Collapse()
    {
        if (store.Preferences.Placement == Placement.Floating) { store.Preferences.SetPlacement(store.Preferences.ReturnPlacement); store.Save(); return; }
        if (!expanded) return; expanded = false; upward = false; Render(true);
    }
    private void MinimizeToTray()
    {
        StopAnimation(); expanded = false; upward = false;
        store.Preferences.SetPlacement(Placement.Tray); store.Save(); Hide();
    }
    private void SetSize(double width, double height, bool animate)
    {
        targetWidth = width; targetHeight = height;
        // Reserve transparent space for centered hover scaling, without resizing or
        // moving the native window on every animation frame. Empty padding is click-through.
        double padding = IsOrb ? OrbPadding * 2 : 0;
        double windowWidth = width + padding, windowHeight = height + padding;
        if (Math.Abs(Width - windowWidth) < .5 && Math.Abs(Height - windowHeight) < .5 && Math.Abs(shell.Width - width) < .5 && Math.Abs(shell.Height - height) < .5) return;
        double oldWidth = shell.ActualWidth > 0 ? shell.ActualWidth : Width, oldHeight = shell.ActualHeight > 0 ? shell.ActualHeight : Height;
        StopAnimation(); shell.Width = width; shell.Height = height;
        if (!animate || !Animate || dragging) { Width = windowWidth; Height = windowHeight; return; }
        // Animate WPF content, not Window dimensions: native WM_SIZE can otherwise overwrite
        // the base value of the other dimension during simultaneous Window animations.
        Width = Math.Max(oldWidth, width) + padding; Height = Math.Max(oldHeight, height) + padding;
        int version = ++animationVersion;
        var duration = TimeSpan.FromMilliseconds(expanded ? 230 : 190); var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        shell.BeginAnimation(WidthProperty, new DoubleAnimation(oldWidth, width, duration) { EasingFunction = ease });
        var animation = new DoubleAnimation(oldHeight, height, duration) { EasingFunction = ease };
        animation.Completed += (_, _) =>
        {
            if (version != animationVersion || dragging) return;
            shell.BeginAnimation(WidthProperty, null); shell.BeginAnimation(HeightProperty, null);
            Width = windowWidth; Height = windowHeight;
            if (IsOrb) NativeWindow.MoveLogical(this, new(anchorX, anchorY));
            RefreshNativeStyle(); NativeWindow.Clamp(this);
            UpdateOrbHover(IsMouseOver);
        };
        shell.BeginAnimation(HeightProperty, animation);
    }
    private void StopAnimation()
    {
        animationVersion++; shell.BeginAnimation(WidthProperty, null); shell.BeginAnimation(HeightProperty, null);
        if (targetWidth > 0 && targetHeight > 0) { double padding = IsOrb ? OrbPadding * 2 : 0; Width = targetWidth + padding; Height = targetHeight + padding; }
        while (canvas.Children.Count > 1) canvas.Children.RemoveAt(1);
    }
    private void RefreshNativeStyle() => NativeWindow.Style(this, store.Preferences.Dark);
    private void UpdateOrbHover(bool hovered, bool immediate = false)
    {
        double target = IsOrb && Animate && hovered && !dragging && !menuOpen ? 1.12 : 1;
        double current = orbHover.ScaleX;
        if (!immediate && Math.Abs(current - target) < .001 && !orbHover.HasAnimatedProperties) return;
        orbHover.BeginAnimation(ScaleTransform.ScaleXProperty, null);
        orbHover.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        orbHover.ScaleX = orbHover.ScaleY = target;
        if (immediate || !Animate || !IsOrb) return;
        var animation = new DoubleAnimation(current, target, TimeSpan.FromMilliseconds(hovered ? 200 : 260))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }, FillBehavior = FillBehavior.Stop
        };
        orbHover.BeginAnimation(ScaleTransform.ScaleXProperty, animation);
        orbHover.BeginAnimation(ScaleTransform.ScaleYProperty, animation);
    }
    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        // Anchors are global screen coordinates expressed in this window's DIPs.
        // Rebase them once for each transition; never mix the old and new units.
        anchorX *= oldDpi.DpiScaleX / newDpi.DpiScaleX;
        anchorY *= oldDpi.DpiScaleY / newDpi.DpiScaleY;
        base.OnDpiChanged(oldDpi, newDpi);
        if (!IsLoaded || closing || dpiRefreshQueued) return;
        dpiRefreshQueued = true;
        Dispatcher.BeginInvoke(() =>
        {
            dpiRefreshQueued = false;
            if (closing) return;
            StopAnimation();
            canvas.InvalidateMeasure(); canvas.InvalidateArrange(); canvas.InvalidateVisual();
            UpdateLayout();
            if (IsOrb) ReadAnchor();
            RefreshNativeStyle(); NativeWindow.Redraw(this);
        }, DispatcherPriority.Loaded);
    }
    private void OrbDown(object sender, MouseButtonEventArgs e)
    { StopAnimation(); dragStart = PointToScreen(e.GetPosition(this)); moved = false; shell.CaptureMouse(); e.Handled = true; }
    private void OrbMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (dragStart is not { } start || e.LeftButton != MouseButtonState.Pressed) return;
        var current = PointToScreen(e.GetPosition(this)); var difference = current - start;
        if (!moved && Math.Abs(difference.X) + Math.Abs(difference.Y) < 5) return;
        moved = true;
        if (!dragging) { dragging = true; UpdateOrbHover(false); }
        var bounds = NativeWindow.Bounds(this);
        NativeWindow.Move(this, new(bounds.X + difference.X, bounds.Y + difference.Y)); dragStart = current;
    }
    private void OrbUp(object sender, MouseButtonEventArgs e)
    {
        shell.ReleaseMouseCapture(); dragStart = null; dragging = false;
        if (moved) { NativeWindow.Clamp(this); SaveAnchor(); if (renderQueued) { renderQueued = false; Render(false); } UpdateOrbHover(IsMouseOver); QueueDismissIfOutside(); }
        else Expand(); e.Handled = true;
    }
    private void HeaderDrag(object sender, MouseButtonEventArgs e)
    {
        DependencyObject? target = e.OriginalSource as DependencyObject;
        while (target != null && target != sender) { if (target is ButtonBase) return; target = VisualTreeHelper.GetParent(target); }
        var before = NativeWindow.Bounds(this); StopAnimation(); dragging = true;
        try { DragMove(); } catch (InvalidOperationException) { } finally { dragging = false; }
        NativeWindow.Clamp(this);
        var after = NativeWindow.Bounds(this); var dpi = VisualTreeHelper.GetDpi(this);
        anchorX += (after.X - before.X) / dpi.DpiScaleX; anchorY += (after.Y - before.Y) / dpi.DpiScaleY;
        if (store.Preferences.Placement == Placement.Floating) ReadAnchor();
        store.Preferences.X = anchorX; store.Preferences.Y = anchorY; store.Save(); e.Handled = true;
        if (renderQueued) { renderQueued = false; Render(false); }
        QueueDismissIfOutside();
    }
    private void ReadAnchor() { var position = NativeWindow.LogicalPosition(this); anchorX = position.X; anchorY = position.Y; }
    private void SaveAnchor() { ReadAnchor(); store.Preferences.X = anchorX; store.Preferences.Y = anchorY; store.Save(); }
    private void OnKey(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { Collapse(); e.Handled = true; }
        else if ((Keyboard.Modifiers & ModifierKeys.Control) != 0)
        {
            if (e.Key is Key.OemPlus or Key.Add) { ChangeScale(.05); e.Handled = true; }
            else if (e.Key is Key.OemMinus or Key.Subtract) { ChangeScale(-.05); e.Handled = true; }
            else if (e.Key == Key.OemComma) { OpenSettings(); e.Handled = true; }
        }
    }
    private void ChangeScale(double delta) { store.Preferences.Scale = Preferences.NormalizeScale(store.Preferences.Scale + delta); store.Save(); }
    private void OpenTask(CodexTask task)
    {
        if (task.DeepLink == null) { store.Notice = "任务 ID 不受支持，无法打开。"; store.Notify(); return; }
        OpenUrl(task.DeepLink);
    }
    private void OpenUrl(Uri uri)
    {
        try { Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }); }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException)
        { store.Notice = "无法打开目标，请确认已安装 Codex 和默认浏览器。"; store.Notify(); }
    }
    internal void OpenMenu()
    {
        var menu = new ContextMenu { PlacementTarget = shell, Placement = PlacementMode.MousePoint };
        ActiveMenu = menu; dismissRequestedByMenu = false;
        menu.AddHandler(Mouse.PreviewMouseDownOutsideCapturedElementEvent, new MouseButtonEventHandler((_, _) =>
        {
            dismissRequestedByMenu = !IsPointerWithin(this) && !IsPointerWithin(picker) && !IsPointerWithin(settings);
        }), true);
        bool dark = store.Preferences.Dark; Ui.SetThemeResources(menu, dark);
        void Item(ItemsControl parent, string text, Action action, bool? check = null)
        { var item = new MenuItem { Header = text, IsCheckable = check.HasValue, IsChecked = check ?? false }; item.Click += (_, _) => { dismissRequestedByMenu = false; action(); }; parent.Items.Add(item); }
        Item(menu, "选择任务…", OpenPicker);
        var modes = new MenuItem { Header = "显示方式" }; menu.Items.Add(modes);
        foreach (var mode in Enum.GetValues<Placement>()) Item(modes, PlacementName(mode), () => { store.Preferences.SetPlacement(mode); store.Save(); }, mode == store.Preferences.Placement);
        Item(menu, store.Preferences.Placement == Placement.Floating ? "取消置顶浮窗" : "置顶为常驻浮窗", () => { store.Preferences.SetPlacement(store.Preferences.Placement == Placement.Floating ? store.Preferences.ReturnPlacement : Placement.Floating); store.Save(); });
        menu.Items.Add(new Separator { Style = (Style)menu.FindResource(typeof(Separator)) }); Item(menu, dark ? "切换浅色" : "切换深色", ToggleTheme);
        Item(menu, "监控设置…", OpenSettings); Item(menu, store.Paused ? "恢复任务刷新" : "暂停任务刷新", () => store.SetPaused(!store.Paused));
        Item(menu, "刷新账户额度", () => _ = store.RefreshQuotaAsync(true)); Item(menu, "找回窗口", RecoverWindow);
        if (expanded) Item(menu, "收起", Collapse);
        Item(menu, "最小化到系统托盘", MinimizeToTray);
        menu.Items.Add(new Separator { Style = (Style)menu.FindResource(typeof(Separator)) }); Item(menu, "退出 Codex Top", () => { closing = true; Application.Current.Shutdown(); });
        menu.Opened += (_, _) => { menuOpen = true; UpdateOrbHover(false); };
        menu.Closed += (_, _) => { ActiveMenu = null; menuOpen = false; if (renderQueued) { renderQueued = false; Render(false); } UpdateOrbHover(IsMouseOver); QueueDismissIfOutside(); };
        menuOpen = true; menu.IsOpen = true;
    }
    public static string PlacementName(Placement mode) => mode switch { Placement.Top => "屏幕顶部", Placement.Floating => "常驻浮窗", Placement.Orb => "桌面圆环", _ => "仅系统托盘" };
    private static bool IsPointerWithin(Window? window) => window?.IsVisible == true && window.InputHitTest(Mouse.GetPosition(window)) != null;
    private void ToggleTheme()
    {
        var origin = Mouse.GetPosition(canvas); BitmapSource? old = null;
        if (Animate && ActualWidth > 0 && ActualHeight > 0)
        {
            var dpi = VisualTreeHelper.GetDpi(this); var bitmap = new RenderTargetBitmap((int)Math.Ceiling(ActualWidth * dpi.DpiScaleX), (int)Math.Ceiling(ActualHeight * dpi.DpiScaleY), 96 * dpi.DpiScaleX, 96 * dpi.DpiScaleY, PixelFormats.Pbgra32); bitmap.Render(shell); bitmap.Freeze(); old = bitmap;
        }
        store.Preferences.Dark = !store.Preferences.Dark; store.Save(); Render(false);
        if (old == null) return;
        var image = new System.Windows.Controls.Image { Source = old, IsHitTestVisible = false, Stretch = Stretch.Fill };
        var circle = new EllipseGeometry(origin, 0, 0);
        var outline = new RectangleGeometry(new(0, 0, ActualWidth, ActualHeight), IsOrb ? 22 : shell.CornerRadius.TopLeft, IsOrb ? 22 : shell.CornerRadius.TopLeft);
        image.Clip = new CombinedGeometry(GeometryCombineMode.Exclude, outline, circle); canvas.Children.Add(image);
        double radius = Math.Sqrt(Math.Pow(Math.Max(Math.Abs(origin.X), Math.Abs(ActualWidth - origin.X)), 2) + Math.Pow(Math.Max(Math.Abs(origin.Y), Math.Abs(ActualHeight - origin.Y)), 2));
        var reveal = new DoubleAnimation(0, radius, TimeSpan.FromMilliseconds(420)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
        reveal.Completed += (_, _) => canvas.Children.Remove(image); circle.BeginAnimation(EllipseGeometry.RadiusXProperty, reveal); circle.BeginAnimation(EllipseGeometry.RadiusYProperty, reveal);
    }
    internal void OpenPicker()
    {
        if (picker != null) { picker.WindowState = WindowState.Normal; picker.Show(); picker.Activate(); return; }
        picker = new TaskPickerWindow(store) { Owner = this }; ObserveDialog(picker); picker.Closed += (_, _) => picker = null; picker.Show();
    }
    internal void OpenSettings()
    {
        if (settings != null) { settings.WindowState = WindowState.Normal; settings.Show(); settings.Activate(); return; }
        settings = new SettingsWindow(store) { WindowStartupLocation = WindowStartupLocation.CenterScreen }; ObserveDialog(settings); settings.Closed += (_, _) => settings = null; settings.Show();
    }
    public void RecoverWindow()
    {
        if (store.Preferences.Placement == Placement.Tray) { PositionAtTray(); Expand(); }
        else { Show(); NativeWindow.Clamp(this); Expand(); Activate(); }
    }
    private void DisplayChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(() =>
    {
        if (closing) return;
        StopAnimation(); NativeWindow.Clamp(this);
        anchorX = Math.Clamp(anchorX, NativeWindow.WorkArea(this).Left, NativeWindow.WorkArea(this).Right - OrbHostSize);
        anchorY = Math.Clamp(anchorY, NativeWindow.WorkArea(this).Top, NativeWindow.WorkArea(this).Bottom - OrbHostSize);
        Render(false); UpdateLayout(); RefreshNativeStyle(); NativeWindow.Redraw(this);
    });
    protected override void OnClosed(EventArgs e)
    {
        closing = true; clock.Stop(); hoverClose.Stop(); dismissCheck.Stop(); store.Changed -= OnStoreChanged;
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged -= DisplayChanged; tray?.Dispose(); store.Dispose(); base.OnClosed(e);
        Application.Current.Shutdown();
    }
}
