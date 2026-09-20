using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Interop;
using CodexTop.Core;
using CodexTop.Windows;
using Application = System.Windows.Application;
using NativeWindow = CodexTop.Windows.NativeWindow;

internal static class OrbFeedbackChecks
{
    public static int Run(bool visual)
    {
        var root = Path.Combine(Path.GetTempPath(), "CodexTop.OrbFeedback", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var id = Guid.NewGuid().ToString();
        var otherId = Guid.NewGuid().ToString();
        var log = Path.Combine(root, "synthetic.jsonl");
        var otherLog = Path.Combine(root, "other.jsonl");
        var now = DateTimeOffset.UtcNow;
        File.WriteAllText(log, "");
        File.WriteAllText(otherLog, "");
        // This database is created exclusively in this test's new temporary directory.
        if (sqlite3_open_v2(Path.Combine(root, "state_5.sqlite"), out var db, 6, null) != 0) throw new IOException("Cannot create synthetic fixture.");
        try
        {
            var sql = "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER,source TEXT);" +
                $"INSERT INTO threads VALUES('{id}','圆环完成提示检查','合成测试','{log.Replace("'", "''")}',{now.ToUnixTimeSeconds()},{now.ToUnixTimeSeconds()},0,'cli');" +
                $"INSERT INTO threads VALUES('{otherId}','另一项合成任务','合成测试','{otherLog.Replace("'", "''")}',{now.ToUnixTimeSeconds()},{now.ToUnixTimeSeconds()},0,'cli');";
            if (sqlite3_exec(db, sql, 0, 0, out var error) != 0) { sqlite3_free(error); throw new IOException("Cannot initialize synthetic fixture."); }
        }
        finally { sqlite3_close(db); }
        new PreferencesFile(Path.Combine(root, "settings.json")).Save(new Preferences
        {
            Initialized = true, AutoMonitor = false, Dark = false, Placement = Placement.Orb,
            SelectedIds = [id], CodexHome = root, CliPath = Path.Combine(root, "disabled-cli.exe"), X = 300, Y = 250
        });
        int checks = 0, failures = 0, turn = 0;
        void Check(bool passed, string name) { checks++; Console.WriteLine((passed ? "PASS " : "FAIL ") + name); if (!passed) failures++; }
        var tracker = new OrbCompletionTracker();
        TaskRow Row(string key, Phase phase)
        {
            var task = new CodexTask(key, "合成任务", "测试", now, now, null, "", new() { Phase = phase });
            return new(task, task);
        }
        Check(tracker.Observe("A", [Row("one", Phase.Completed)], true).Count == 0, "startup history does not count as a new completion");
        tracker.Observe("A", [Row("one", Phase.Running)], true);
        Check(tracker.Observe("A", [Row("one", Phase.Completed)], true).SetEquals(["one"]), "only an observed active-to-completed transition triggers feedback");
        Check(tracker.Observe("A", [Row("one", Phase.Completed), Row("old", Phase.Completed)], true).Count == 0, "refresh and selecting historical completion do not replay feedback");
        tracker.Observe("A", [], true);
        Check(tracker.Observe("A", [Row("one", Phase.Completed)], true).Count == 0, "removing and reselecting a completed task does not replay");
        tracker.Observe("A", [Row("one", Phase.Running)], true);
        Check(tracker.Observe("B", [Row("one", Phase.Completed)], true).Count == 0, "changing data source clears previous activity");
        tracker.Observe("B", [Row("one", Phase.Running)], true);
        tracker.Observe("B", [], false);
        Check(tracker.Observe("B", [Row("one", Phase.Completed)], true).Count == 0, "resuming after unavailable data does not invent a transition");
        foreach (var phase in new[] { Phase.Unknown, Phase.Stopped, Phase.Failed })
        {
            tracker.Observe("B", [Row("one", phase)], true);
            Check(tracker.Observe("B", [Row("one", Phase.Completed)], true).Count == 0, phase + " correction is not a freshly completed running task");
        }
        tracker.Observe("B", [Row("one", Phase.Running), Row("two", Phase.Waiting)], true);
        Check(tracker.Observe("B", [Row("one", Phase.Completed), Row("two", Phase.Completed)], true).Count == 2, "simultaneous completions are grouped into one cue");
        void Append(string type, bool other = false)
        {
            if (!other && type == "task_started") turn++;
            File.AppendAllText(other ? otherLog : log, JsonSerializer.Serialize(new { timestamp = DateTimeOffset.UtcNow, type = "event_msg", payload = new { type, turn_id = other ? "other-turn" : "test-" + turn, call_id = "synthetic-question" } }) + "\n");
        }
        Append("task_started");
        Append("task_complete");
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        using var store = new MonitorStore(app.Dispatcher, root);
        var window = new MonitorWindow(store) { Title = "Codex Top · 圆环完成检查" };
        FrameworkElement? Marker() => Descendants(window).OfType<FrameworkElement>().FirstOrDefault(e => e.GetType().Name == "CompletionMark");
        string NoticeText() => string.Join(" ", Descendants(window.CompletionNotice.Child).OfType<TextBlock>().Select(t => t.Text));
        bool EmptyCenter() => Marker() is null && !Descendants(window).OfType<TextBlock>().Any(t => t.Text is "0" or "✓");
        double Progress() => (double?)Marker()?.GetType().GetProperty("Progress")?.GetValue(Marker()) ?? 1;
        string Frame()
        {
            if (Marker() is not { } mark) return "missing";
            var bitmap = new RenderTargetBitmap(64, 64, 192, 192, PixelFormats.Pbgra32);
            bitmap.Render(mark); var pixels = new byte[64 * 64 * 4]; bitmap.CopyPixels(pixels, 64 * 4, 0);
            return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(pixels));
        }
        async Task WaitFor(Phase phase, bool other = false)
        {
            store.RequestRefresh(); var deadline = DateTime.UtcNow.AddSeconds(5);
            string target = other ? otherId : id;
            while ((store.Loading || store.Rows.FirstOrDefault(r => r.Root.Id == target)?.Activity.Phase != phase) && DateTime.UtcNow < deadline) await Task.Delay(15);
            window.UpdateLayout();
            Check(store.Rows.FirstOrDefault(r => r.Root.Id == target)?.Activity.Phase == phase, "synthetic source reached " + phase);
        }
        window.Loaded += async (_, _) =>
        {
            try
            {
                await WaitFor(Phase.Completed);
                Check(EmptyCenter() && !window.CompletionNotice.IsOpen, "startup completed history has an empty orb and no completion notice");
                store.Preferences.SelectedIds.Clear(); store.Save(); window.UpdateLayout();
                Check(EmptyCenter() && !window.CompletionNotice.IsOpen, "no selected tasks leaves an empty default orb");
                store.Preferences.SelectedIds.Add(id); store.Save(); window.UpdateLayout();
                Check(EmptyCenter() && !window.CompletionNotice.IsOpen, "selecting completed history does not show a check or notice");
                Append("task_started");
                await WaitFor(Phase.Running);
                Check(Descendants(window).OfType<TextBlock>().Any(t => t.Text == "1"), "running count is one");
                Check(Marker() == null, "running task has no completed indicator");
                var before = NativeWindow.Bounds(window);
                var foreground = GetForegroundWindow();
                Append("task_complete"); await WaitFor(Phase.Completed);
                Check(Marker() != null && Progress() < 1, "completion begins a visible drawing transition");
                Check(window.CompletionNotice.IsOpen && NoticeText().Contains("任务已完成") && NoticeText().Contains("圆环完成提示检查"), "completion automatically opens a notice with the task name");
                Check(((Border)((Grid)window.Content).Children[0]).ToolTip is null, "completion card replaces the duplicate hover tooltip");
                Check(GetForegroundWindow() == foreground, "completion notice does not take keyboard focus");
                var firstFrame = Frame();
                await Task.Delay(180); double middle = Progress();
                Check(middle > 0 && middle < 1, "completion has a rendered intermediate frame");
                var middleFrame = Frame();
                Check(firstFrame != middleFrame, "completion pixels change between initial and intermediate frames");
                store.Notice = "合成刷新提示"; store.Notify(); window.UpdateLayout();
                Check(Progress() >= middle, "unrelated refresh does not restart the drawing");
                await Task.Delay(1800); window.UpdateLayout();
                Check(Marker() != null && Progress() == 1 && window.CompletionNotice.IsOpen, "completion notice stays readable after the drawing finishes");
                Check(Frame() != middleFrame, "final check pixels differ from the transient halo and partial stroke");
                Check(NativeWindow.Bounds(window) == before, "feedback keeps the native window bounds fixed");
                CheckNotice(window, false, Check);
                await Task.Delay(3300); window.UpdateLayout();
                Check(EmptyCenter() && !window.CompletionNotice.IsOpen, "completion expires to an empty orb without a permanent check");
                store.Preferences.Dark = true; store.Save(); window.UpdateLayout();
                Check(EmptyCenter() && !window.CompletionNotice.IsOpen, "theme change does not replay historical completion");
                Append("task_started"); await WaitFor(Phase.Running);
                Check(Marker() == null, "a new turn immediately restores the running count");
                store.Preferences.ReduceMotion = true; store.Save();
                Append("task_complete"); await WaitFor(Phase.Completed);
                Check(Marker() != null && Progress() == 1, "reduced motion still gives a static completion check");
                Check(window.CompletionNotice.IsOpen && window.CompletionNotice.PopupAnimation == System.Windows.Controls.Primitives.PopupAnimation.None, "reduced motion keeps a readable notice without popup animation");
                CheckNotice(window, true, Check);
                Append("task_started"); await WaitFor(Phase.Running);
                Check(!window.CompletionNotice.IsOpen, "restarting the completed task dismisses stale information");
                Append("turn_aborted"); await WaitFor(Phase.Stopped);
                Check(Marker() == null, "stopped task is not reported as completed");
                Append("task_started"); await WaitFor(Phase.Running);
                Append("request_user_input"); await WaitFor(Phase.Waiting);
                Check(!Descendants(window).OfType<TextBlock>().Any(t => t.Text == "!"), "waiting orb has no tiny exclamation bar above the number");
                Check(AlertPixelsInsideRing(window) == 0, "waiting orb inner upper-right area is free of stray orange marks");
                store.Preferences.ReduceMotion = false; store.Save();
                Append("task_complete"); await WaitFor(Phase.Completed);
                Check(Marker() != null && Progress() < 1, "waiting-to-completed transition animates once");
                Append("task_started"); await WaitFor(Phase.Running);
                Check(Marker() == null, "new activity cancels an in-flight completion check");
                Append("task_failed"); await WaitFor(Phase.Failed);
                Check(Marker() == null && !Descendants(window).OfType<TextBlock>().Any(t => t.Text == "!"), "failure preserves status without a stray bar or success check");
                Append("task_started"); await WaitFor(Phase.Running);
                Append("task_started", true); store.Preferences.SelectedIds.Add(otherId); store.Save(); await WaitFor(Phase.Running, true);
                Append("task_complete"); await WaitFor(Phase.Completed);
                Check(Marker() != null && Progress() < 1, "individual completion is visible while another task runs");
                var shell = (Border)((Grid)window.Content).Children[0];
                Check(AutomationProperties.GetName(shell).Contains("1 项运行中"), "completion feedback still identifies remaining running work");
                await Task.Delay(5300); window.UpdateLayout();
                Check(Marker() == null && Descendants(window).OfType<TextBlock>().Any(t => t.Text == "1"), "feedback expires back to the remaining running count");
                Check(!window.CompletionNotice.IsOpen, "completion notice automatically closes with its cue");
                Append("request_user_input", true); await WaitFor(Phase.Waiting, true);
                Append("task_started"); await WaitFor(Phase.Running);
                Append("task_complete"); await WaitFor(Phase.Completed);
                Check(AutomationProperties.GetName(shell).Contains("待处理"), "completion does not conceal another task needing input");
                store.Preferences.SetPlacement(Placement.Floating); store.Save();
                Append("task_started"); await WaitFor(Phase.Running);
                Append("task_complete"); await WaitFor(Phase.Completed);
                Check(window.CompletionNotice.IsOpen && NoticeText().Contains("圆环完成提示检查"), "an already expanded floating monitor also announces completion");
                store.Preferences.SetPlacement(Placement.Orb); store.Save(); window.UpdateLayout();
                Check(Marker() == null && !window.CompletionNotice.IsOpen, "switching display mode discards transient completion feedback");
                Append("task_started"); Append("task_started", true); await WaitFor(Phase.Running);
                Append("task_complete"); Append("task_complete", true); await WaitFor(Phase.Completed); await WaitFor(Phase.Completed, true);
                Check(window.CompletionNotice.IsOpen && NoticeText().Contains("2 项任务已完成") && NoticeText().Contains("另一项合成任务"), "simultaneous completions produce one notice containing both task names");
                window.OpenMenu();
                Check(!window.CompletionNotice.IsOpen && Marker() is null, "opening the menu dismisses the notice and transient check");
                window.ActiveMenu!.IsOpen = false;
                await Task.Delay(300);
                store.Preferences.SetPlacement(Placement.Tray); store.Save();
                Append("task_started"); await WaitFor(Phase.Running);
                Append("task_complete"); await WaitFor(Phase.Completed);
                Check(!window.IsVisible && !window.CompletionNotice.IsOpen, "hidden tray mode does not open a stray desktop popup");
                store.Preferences.SetPlacement(Placement.Orb); store.Save(); window.UpdateLayout();
                Check(EmptyCenter() && !window.CompletionNotice.IsOpen, "returning from tray does not replay a past completion");
                File.Delete(otherLog); // Only this test's synthetic file is removed.
                Append("task_started"); await WaitFor(Phase.Running);
                Check(store.Error is not null, "an unrelated unreadable task produces a partial source warning");
                Append("task_complete"); await WaitFor(Phase.Completed);
                Check(Marker() != null && Progress() < 1, "partial source warnings do not suppress valid task completion feedback");
                Check(window.CompletionNotice.IsOpen, "partial source warnings preserve the completion information card");
                foreach (var screen in System.Windows.Forms.Screen.AllScreens)
                {
                    var area = screen.WorkingArea;
                    NativeWindow.Move(window, new(area.Right - 100, area.Top + area.Height / 2));
                    await Task.Delay(100);
                    typeof(MonitorWindow).GetMethod("ReadAnchor", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!.Invoke(window, null);
                    Append("task_started"); await WaitFor(Phase.Running);
                    Append("task_complete"); await WaitFor(Phase.Completed);
                    await Task.Delay(200);
                    CheckNotice(window, true, Check);
                    Check(NoticeBounds(window).Right <= NativeWindow.Bounds(window).Left - 8, "notice flips left with a gap near the monitor's right edge");
                }
                window.Hide();
                Check(!window.CompletionNotice.IsOpen, "hiding the owner closes its completion popup");
                window.Show();
            }
            catch (Exception error) { failures++; Console.WriteLine(error); }
            finally
            {
                Console.WriteLine($"Orb feedback checks: {checks}, failures: {failures}.");
                if (visual)
                {
                    NativeWindow.MoveLogical(window, new(300, 250));
                    typeof(MonitorWindow).GetMethod("ReadAnchor", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!.Invoke(window, null);
                    store.Preferences.Dark = false; store.Preferences.ReduceMotion = false; store.Save();
                    window.ShowInTaskbar = true;
                    window.PreviewKeyDown += async (_, e) =>
                    {
                        if (e.Key == System.Windows.Input.Key.F6) { Append("task_started"); await WaitFor(Phase.Running); }
                        if (e.Key == System.Windows.Input.Key.F7) { Append("task_complete"); await WaitFor(Phase.Completed); }
                        if (e.Key == System.Windows.Input.Key.F8) { Append("task_complete"); Append("task_complete", true); await WaitFor(Phase.Completed); await WaitFor(Phase.Completed, true); }
                        if (e.Key == System.Windows.Input.Key.F9) { Append("task_started"); Append("request_user_input"); await WaitFor(Phase.Waiting); }
                    };
                    Append("task_started"); store.RequestRefresh();
                    Console.WriteLine("Visual checks: F6 start, F7 complete, F8 finish all, F9 waiting.");
                }
                else window.Close();
            }
        };
        app.Run(window); return failures == 0 ? 0 : 1;
    }
    private static Rect NoticeBounds(MonitorWindow window)
    {
        var source = (HwndSource)PresentationSource.FromVisual(window.CompletionNotice.Child);
        GetWindowRect(source.Handle, out var rect);
        return new(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top);
    }
    private static void CheckNotice(MonitorWindow window, bool dark, Action<bool, string> check)
    {
        window.CompletionNotice.Child.UpdateLayout();
        var card = (Border)window.CompletionNotice.Child;
        var source = (HwndSource)PresentationSource.FromVisual(card);
        var style = GetWindowLongPtr(source.Handle, -20).ToInt64();
        check((style & 0x80) != 0 && (style & 0x40000) == 0, "notice is a tool window without a taskbar entry");
        var bounds = NoticeBounds(window);
        var monitor = System.Windows.Forms.Screen.FromPoint(new((int)(bounds.X + bounds.Width / 2), (int)(bounds.Y + bounds.Height / 2))).WorkingArea;
        check(bounds.Left >= monitor.Left && bounds.Right <= monitor.Right && bounds.Top >= monitor.Top && bounds.Bottom <= monitor.Bottom, "notice stays inside the monitor work area");
        var dpi = VisualTreeHelper.GetDpi(card);
        int width = (int)Math.Ceiling(card.ActualWidth * dpi.DpiScaleX), height = (int)Math.Ceiling(card.ActualHeight * dpi.DpiScaleY);
        var bitmap = new RenderTargetBitmap(width, height, dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        bitmap.Render(card); var pixels = new byte[width * height * 4]; bitmap.CopyPixels(pixels, width * 4, 0);
        check(pixels[3] == 0 && pixels[(width - 1) * 4 + 3] == 0 && pixels[(height - 1) * width * 4 + 3] == 0, "rounded notice corners are transparent");
        int center = ((height / 2) * width + width - 8) * 4;
        check(pixels[center + 3] == 255 && (dark ? pixels[center] < 70 : pixels[center] > 230), "notice background follows the current theme");
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i); yield return child;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }
    private static int AlertPixelsInsideRing(Window window)
    {
        var dpi = VisualTreeHelper.GetDpi(window);
        int width = (int)Math.Round(window.ActualWidth * dpi.DpiScaleX), height = (int)Math.Round(window.ActualHeight * dpi.DpiScaleY);
        var bitmap = new RenderTargetBitmap(width, height, dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        bitmap.Render(window); var pixels = new byte[width * height * 4]; bitmap.CopyPixels(pixels, width * 4, 0);
        int count = 0;
        for (int y = 0; y < height; y++) for (int x = 0; x < width; x++)
        {
            double dx = (x + .5 - width / 2d) / dpi.DpiScaleX, dy = (y + .5 - height / 2d) / dpi.DpiScaleY;
            double radius = Math.Sqrt(dx * dx + dy * dy);
            if (dx < 7 || dy > -5 || radius < 13 || radius > 16) continue;
            int i = (y * width + x) * 4;
            if (pixels[i + 3] > 200 && pixels[i + 2] > pixels[i + 1] * 1.4 && pixels[i + 1] > pixels[i] * 1.5) count++;
        }
        return count;
    }
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out nint db, int flags, string? vfs);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_exec(nint db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, nint callback, nint argument, out nint error);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_close(nint db);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern void sqlite3_free(nint pointer);
    [StructLayout(LayoutKind.Sequential)] private struct PixelRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32")] private static extern nint GetForegroundWindow();
    [DllImport("user32")] private static extern bool GetWindowRect(nint hwnd, out PixelRect rect);
    [DllImport("user32", EntryPoint = "GetWindowLongPtrW")] private static extern nint GetWindowLongPtr(nint hwnd, int index);
}
