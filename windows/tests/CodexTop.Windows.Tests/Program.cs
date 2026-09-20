using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CodexTop.Core;
using CodexTop.Windows;
using Application = System.Windows.Application;
using ComboBox = System.Windows.Controls.ComboBox;
using Color = System.Windows.Media.Color;
using ColorConverter = System.Windows.Media.ColorConverter;
using MouseEventArgs = System.Windows.Input.MouseEventArgs;
using NativeWindow = CodexTop.Windows.NativeWindow;

internal static class Program
{
    private static int failures, checks;
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--fixture") return InlineSelectionChecks.Run(args[1]);
        if (args.Contains("--orb-feedback")) return OrbFeedbackChecks.Run(args.Contains("--visual"));
        // Exercise only windows created by this process, using isolated preferences.
        string temporary = Path.Combine(Path.GetTempPath(), "CodexTop.Windows.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        new PreferencesFile(Path.Combine(temporary, "settings.json")).Save(new Preferences
        {
            Initialized = true, AutoMonitor = false, Dark = false, Placement = Placement.Orb,
            CodexHome = temporary, CliPath = Path.Combine(temporary, "not-installed.exe")
        });
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        using var store = new MonitorStore(app.Dispatcher, temporary);
        var window = new MonitorWindow(store);
        window.Loaded += async (_, _) =>
        {
            try
            {
                await Task.Delay(400);
                var screens = System.Windows.Forms.Screen.AllScreens;
                Console.WriteLine(JsonSerializer.Serialize(screens.Select(s => new { s.DeviceName, s.Bounds, s.WorkingArea })));
                var dpis = new HashSet<uint>();
                foreach (var screen in screens.Concat(screens.Reverse()))
                {
                    var area = screen.WorkingArea;
                    var handle = new WindowInteropHelper(window).Handle;
                    SetWindowPos(handle, 0, area.Left + area.Width / 2, area.Top + area.Height / 2, 0, 0, 0x0015);
                    await Task.Delay(450);
                    uint dpi = GetDpiForWindow(handle); dpis.Add(dpi);
                    foreach (bool dark in new[] { false, true })
                    {
                        store.Preferences.Dark = dark; store.Save(); await Task.Delay(100);
                        Console.WriteLine($"{screen.DeviceName} / {dpi} DPI / dark={dark}");
                        CheckGeometry(window, dark);
                        GetWindowRect(handle, out var before);
                        window.RecoverWindow(); await Task.Delay(350);
                        CheckPanel(window, dark);
                        window.RaiseEvent(new System.Windows.Input.KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, Key.Escape) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
                        await Task.Delay(300);
                        CheckGeometry(window, dark);
                        GetWindowRect(handle, out var after);
                        Check(Math.Abs(after.Left - before.Left) <= 1 && Math.Abs(after.Top - before.Top) <= 1, "expand/collapse keeps this monitor's anchor");
                        window.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, Environment.TickCount) { RoutedEvent = Mouse.MouseEnterEvent });
                        await Task.Delay(260);
                        var shell = (Border)((Grid)window.Content).Children[0];
                        double hoverScale = ((ScaleTransform)shell.RenderTransform).ScaleX;
                        Check(Math.Abs(hoverScale - 1.12) < .001, "hover enlarges the circle");
                        CheckTransparentEdge(window, dark, "orb", hoverScale);
                        GetWindowRect(handle, out var hovered);
                        Check(hovered.Left == after.Left && hovered.Top == after.Top && hovered.Right == after.Right && hovered.Bottom == after.Bottom, "hover preserves native bounds and center");
                        window.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, Environment.TickCount) { RoutedEvent = Mouse.MouseLeaveEvent });
                        await Task.Delay(320);
                        Check(Math.Abs(((ScaleTransform)shell.RenderTransform).ScaleX - 1) < .001, "leaving restores normal size");
                    }
                }
                await CheckSettings(store);
                await CheckDismissal(window, store);
                window.WindowState = WindowState.Minimized; await Task.Delay(150);
                Check(!window.IsVisible && store.Preferences.Placement == Placement.Tray, "minimize hides to tray");
                window.RecoverWindow(); await Task.Delay(300);
                Check(window.IsVisible && !window.ShowInTaskbar, "tray restore remains outside taskbar");
                Console.WriteLine($"Actual monitors: {screens.Length}; DPI values: {string.Join(',', dpis)}.");
                if (dpis.Count < 2) Console.WriteLine("Mixed-DPI hardware transition not available on this desktop.");
            }
            catch (Exception error) { failures++; Console.WriteLine(error); }
            finally
            {
                Console.WriteLine($"Windows checks: {checks}, failures: {failures}.");
                if (args.Contains("--visual"))
                {
                    // Only test windows are discoverable by native screenshot tools.
                    window.Title = "Codex Top · 边缘检查"; window.ShowInTaskbar = true;
                    store.Preferences.Dark = args.Contains("--visual-dark");
                    store.Preferences.SetPlacement(args.Contains("--visual-panel") ? Placement.Floating : Placement.Orb); store.Save();
                    if (args.Contains("--visual-settings")) new SettingsWindow(store) { ShowInTaskbar = true, WindowStartupLocation = WindowStartupLocation.CenterScreen }.Show();
                    if (args.Contains("--visual-dismiss"))
                    {
                        new Window { Title = "Codex Top · 外部点击测试", Width = 280, Height = 180, Left = 50, Top = 80,
                            Content = new TextBlock { Text = "点击这里，检查面板是否回到圆环。", Margin = new Thickness(20), TextWrapping = TextWrapping.Wrap } }.Show();
                        window.RecoverWindow(); window.OpenSettings();
                        Application.Current.Windows.OfType<SettingsWindow>().Single().ShowInTaskbar = true;
                    }
                }
                else window.Close();
            }
        };
        app.Run(window);
        return failures == 0 ? 0 : 1;
    }
    private static void CheckGeometry(MonitorWindow window, bool dark)
    {
        var handle = new WindowInteropHelper(window).Handle;
        uint dpi = GetDpiForWindow(handle); GetClientRect(handle, out var client);
        int expected = (int)Math.Round(56 * dpi / 96.0);
        Check(Math.Abs(VisualTreeHelper.GetDpi(window).PixelsPerInchX - dpi) < .01, "WPF and native DPI agree");
        Check(Math.Abs(client.Right - expected) <= 1 && Math.Abs(client.Bottom - expected) <= 1, "orb host reserves 56 DIP for the 44 DIP circle");
        Check(!window.ShowInTaskbar, "no taskbar entry");
        CheckTransparentEdge(window, dark, "orb");
    }
    private static void CheckPanel(MonitorWindow window, bool dark)
    {
        var handle = new WindowInteropHelper(window).Handle; GetClientRect(handle, out var client);
        Check(Math.Abs(client.Right - 410 * GetDpiForWindow(handle) / 96.0) <= 1, "expanded panel width uses target DPI");
        DwmGetWindowAttribute(handle, 38, out int backdrop, 4);
        Check(backdrop == 1, "panel has no rectangular system backdrop");
        CheckTransparentEdge(window, dark, "panel");
    }
    private static void CheckTransparentEdge(MonitorWindow window, bool dark, string kind, double orbScale = 1)
    {
        var handle = new WindowInteropHelper(window).Handle; GetClientRect(handle, out var client);
        uint dpi = GetDpiForWindow(handle); int width = client.Right, height = client.Bottom;
        var region = CreateRectRgn(0, 0, 0, 0);
        try { Check(GetWindowRgn(handle, region) == 0, "no hard GDI clip over the smooth outline"); }
        finally { DeleteObject(region); }
        Check(window.AllowsTransparency && (GetWindowLongPtrW(handle, -20).ToInt64() & 0x80000) != 0, "native per-pixel transparency enabled");
        var bitmap = new RenderTargetBitmap(width, height, dpi, dpi, PixelFormats.Pbgra32);
        bitmap.Render(window);
        var pixels = new byte[width * height * 4]; bitmap.CopyPixels(pixels, width * 4, 0);
        byte Alpha(int x, int y) => pixels[(y * width + x) * 4 + 3];
        Check(Alpha(0, 0) == 0 && Alpha(width - 1, 0) == 0 && Alpha(0, height - 1) == 0 && Alpha(width - 1, height - 1) == 0, "all rectangular corners fully transparent");
        Check(Alpha(width / 2, height / 2) == 255, "content center remains opaque");
        if (kind == "orb") Check(Alpha(width / 2, 0) == 0 && Alpha(width / 2, height - 1) == 0 && Alpha(0, height / 2) == 0 && Alpha(width - 1, height / 2) == 0, "orb outline fits inside transparent padding without clipping");
        int partial = 0, wrongColor = 0;
        for (int i = 0; i < pixels.Length; i += 4)
        {
            double x = i / 4 % width + .5, y = i / 4 / width + .5;
            double radius = (kind == "orb" ? 22 * orbScale : 20) * dpi / 96.0;
            if (kind == "orb")
            {
                double dx = x - width / 2.0, dy = y - height / 2.0;
                if (dx * dx + dy * dy < Math.Pow(radius - 1.5 * dpi / 96.0, 2)) continue;
            }
            else
            {
                if (x >= radius && x <= width - radius || y >= radius && y <= height - radius) continue;
                double dx = x - (x < radius ? radius : width - radius), dy = y - (y < radius ? radius : height - radius);
                if (dx * dx + dy * dy < Math.Pow(radius - 1.5 * dpi / 96.0, 2)) continue;
            }
            int alpha = pixels[i + 3];
            if (alpha == 0 || alpha == 255) continue;
            partial++;
            // Pbgra32 stores color multiplied by coverage. A native black underlay,
            // white matte, or binary clip would violate this contract in one theme.
            int expectedBlue = dark ? 0 : (int)Math.Round(alpha * 248 / 255.0);
            int expectedOther = dark ? 0 : (int)Math.Round(alpha * 247 / 255.0);
            if (Math.Abs(pixels[i] - expectedBlue) > 2 || Math.Abs(pixels[i + 1] - expectedOther) > 2 || Math.Abs(pixels[i + 2] - expectedOther) > 2)
            {
                if (wrongColor < 4) Console.WriteLine($"Unexpected ({i / 4 % width},{i / 4 / width}): BGRA={pixels[i]},{pixels[i+1]},{pixels[i+2]},{alpha}");
                wrongColor++;
            }
        }
        Console.WriteLine($"{kind} / {dpi} DPI / dark={dark}: {partial} antialiased pixels, {wrongColor} halo pixels");
        Check(partial > 0 && wrongColor == 0, "smooth theme-colored edge without black/white matte");
    }
    private static async Task CheckSettings(MonitorStore store)
    {
        var settings = new SettingsWindow(store); settings.Show(); await Task.Delay(120);
        var theme = Descendants(settings).OfType<ComboBox>().Single(c => AutomationProperties.GetName(c) == "主题");
        foreach (bool dark in new[] { false, true, false })
        {
            theme.SelectedIndex = dark ? 0 : 1; await Task.Delay(100);
            Check(store.Preferences.Dark == dark, "settings theme selection updates shared preference");
            Check(((SolidColorBrush)settings.Background).Color == (Color)ColorConverter.ConvertFromString(dark ? "#171719" : "#F5F5F7"), "already-open settings changes its background");
            Check(((SolidColorBrush)theme.Foreground).Color == (Color)ColorConverter.ConvertFromString(dark ? "#F5F5F7" : "#222226"), "already-open fields change their text color");
            theme.IsDropDownOpen = true; await Task.Delay(80);
            var popup = (System.Windows.Controls.Primitives.Popup)theme.Template.FindName("PART_Popup", theme);
            Check(popup.IsOpen && popup.AllowsTransparency && popup.Child.IsVisible, "rounded theme dropdown opens on a transparent surface");
            theme.IsDropDownOpen = false;
        }
        store.Preferences.Dark = true; store.Save(); await Task.Delay(80);
        Check(theme.SelectedIndex == 0, "external theme change synchronizes existing selector");
        Check(!settings.ShowInTaskbar, "settings stays outside taskbar"); settings.Close();
    }
    private static async Task CheckDismissal(MonitorWindow window, MonitorStore store)
    {
        var outside = new Window { Title = "Codex Top · 点击开始交互检查", Width = 280, Height = 180, Left = 60, Top = 70,
            Content = new TextBlock { Text = "点击此窗口开始焦点检查。\n检查会自动切换测试窗口。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(20) } };
        outside.Show();
        // Activate() can change only the thread's active HWND when Windows denies
        // foreground activation. Require a real foreground test surface before
        // asserting global focus behavior, rather than testing background HWNDs.
        Console.WriteLine("Waiting for the interaction test window to receive foreground focus.");
        var deadline = DateTime.UtcNow.AddSeconds(60);
        while (!NativeWindow.IsForegroundWithin(outside) && DateTime.UtcNow < deadline) await Task.Delay(100);
        if (!NativeWindow.IsForegroundWithin(outside))
        {
            Check(false, "interaction tests require foreground focus; click the test window and rerun"); outside.Close(); return;
        }
        outside.Title = "Codex Top · 外部点击测试";
        store.Preferences.SetPlacement(Placement.Orb); store.Save();
        window.RecoverWindow(); await Task.Delay(300);
        outside.Activate(); await Task.Delay(350);
        Check(window.Width == 56 && window.Height == 56, "external activation collapses orb panel");

        window.RecoverWindow(); await Task.Delay(300);
        outside.Activate(); window.Activate(); await Task.Delay(350);
        Console.WriteLine($"Rapid focus: main active={window.IsActive}, outside active={outside.IsActive}, width={window.Width}, family={NativeWindow.IsForegroundWithin(window)}, foreground={GetForegroundWindow()}, main={new WindowInteropHelper(window).Handle}");
        Check(window.Width > 56, "queued old deactivation does not collapse a reactivated panel");

        window.RecoverWindow(); await Task.Delay(300);
        window.OpenSettings(); await Task.Delay(150);
        var settings = Application.Current.Windows.OfType<SettingsWindow>().Single();
        Check(window.Width > 56, "settings interaction keeps its panel open");
        var owned = new Window { Owner = settings, Title = "Owned dialog test", Width = 180, Height = 100, ShowInTaskbar = false };
        owned.Show(); await Task.Delay(150);
        Console.WriteLine($"Owned focus: active={owned.IsActive}, settings={settings.IsActive}, width={window.Width}, foreground={GetForegroundWindow()}, owned={new WindowInteropHelper(owned).Handle}, settings={new WindowInteropHelper(settings).Handle}");
        Check(window.Width > 56 && NativeWindow.IsForegroundWithin(window, settings), "owned dialog focus stays within the tool");
        owned.Close(); settings.Activate();
        outside.Activate(); await Task.Delay(350);
        Check(window.Width == 56 && window.Height == 56, "outside activation collapses even with settings still visible");
        settings.Close();

        window.RecoverWindow(); await Task.Delay(300);
        window.OpenPicker(); await Task.Delay(150);
        var picker = Application.Current.Windows.OfType<TaskPickerWindow>().Single();
        Check(window.Width > 56, "task picker keeps its panel open while active");
        outside.Activate(); await Task.Delay(350);
        Check(window.Width == 56, "outside activation collapses with task picker still visible");
        picker.Close();

        window.RecoverWindow(); await Task.Delay(300);
        window.OpenSettings(); await Task.Delay(150);
        settings = Application.Current.Windows.OfType<SettingsWindow>().Single();
        window.Activate(); await Task.Delay(100);
        Check(window.Width > 56, "moving focus from settings back to panel does not collapse");
        settings.Hide(); await Task.Delay(150);
        Check(window.Width > 56, "hiding background settings does not collapse active panel");
        outside.Activate(); await Task.Delay(350);
        Check(window.Width == 56, "hidden settings cannot block collapse"); settings.Close();

        window.RecoverWindow(); await Task.Delay(300);
        window.OpenMenu(); await Task.Delay(100);
        window.ActiveMenu!.IsOpen = false; await Task.Delay(350);
        Check(window.Width > 56, "closing menu within active tool keeps panel open");
        window.RecoverWindow(); await Task.Delay(300);
        window.OpenMenu(); await Task.Delay(100);
        var menu = window.ActiveMenu!;
        outside.Activate(); await Task.Delay(50);
        menu.IsOpen = false;
        // Popup close animation, dismissal debounce and panel shrink are separate
        // phases; wait for the behavioral endpoint rather than one fixed frame.
        await WaitUntil(() => window.Width == 56 && window.Height == 56);
        Console.WriteLine($"After outside menu close: width={window.Width}, menu={menu.IsOpen}, main active={window.IsActive}, outside active={outside.IsActive}, foreground={GetForegroundWindow()}");
        Check(window.Width == 56 && window.Height == 56, "menu close rechecks a previously skipped deactivation");

        store.Preferences.SetPlacement(Placement.Tray); store.Save(); window.RecoverWindow(); await Task.Delay(300);
        window.OpenSettings(); await Task.Delay(150);
        settings = Application.Current.Windows.OfType<SettingsWindow>().Single();
        outside.Activate(); await Task.Delay(350);
        Check(!window.IsVisible && store.Preferences.Placement == Placement.Tray, "outside activation returns tray panel to tray with settings open");
        settings.Close();

        store.Preferences.SetPlacement(Placement.Floating); store.Save(); await Task.Delay(200);
        outside.Activate(); await Task.Delay(300);
        Check(window.IsVisible && window.Width > 56 && store.Preferences.Placement == Placement.Floating, "pinned floating mode remains open");
        outside.Close(); store.Preferences.SetPlacement(Placement.Orb); store.Save();
    }
    private static async Task WaitUntil(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(2);
        while (!condition() && DateTime.UtcNow < deadline) await Task.Delay(25);
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i); yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
    private static void Check(bool success, string description)
    { checks++; if (!success) { failures++; Console.WriteLine("FAIL " + description); } }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32")] private static extern uint GetDpiForWindow(nint hwnd);
    [DllImport("user32")] private static extern nint GetForegroundWindow();
    [DllImport("user32")] private static extern nint GetWindowLongPtrW(nint hwnd, int index);
    [DllImport("dwmapi")] private static extern int DwmGetWindowAttribute(nint hwnd, int attribute, out int value, int size);
    [DllImport("user32")] private static extern bool GetClientRect(nint hwnd, out Rect rect);
    [DllImport("user32")] private static extern bool GetWindowRect(nint hwnd, out Rect rect);
    [DllImport("user32")] private static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32")] private static extern int GetWindowRgn(nint hwnd, nint region);
    [DllImport("gdi32")] private static extern nint CreateRectRgn(int left, int top, int right, int bottom);
    [DllImport("gdi32")] private static extern bool DeleteObject(nint obj);
}
