using System.Runtime.InteropServices;
using System.Windows.Interop;
using CodexTop.Core;
using Microsoft.Win32;

namespace CodexTop.Windows;

internal static class NativeWindow
{
    public static void Style(Window window, bool dark)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == 0) return;
        int theme = dark ? 1 : 0; DwmSetWindowAttribute(hwnd, 20, ref theme, 4);
        int corner = 1; DwmSetWindowAttribute(hwnd, 33, ref corner, 4);
        // WPF's layered surface owns the antialiased outline in both themes.
        // Do not combine it with a binary region or a rectangular system backdrop.
        int backdrop = 1; DwmSetWindowAttribute(hwnd, 38, ref backdrop, 4);
        int nonClient = 1; DwmSetWindowAttribute(hwnd, 2, ref nonClient, 4); // DWMNCRP_DISABLED
        var margins = new Margins(); DwmExtendFrameIntoClientArea(hwnd, ref margins);
        SetWindowRgn(hwnd, 0, true);
    }
    public static void StyleDialog(Window window, bool dark)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == 0) return;
        int theme = dark ? 1 : 0; DwmSetWindowAttribute(hwnd, 20, ref theme, 4);
        int corner = 2; DwmSetWindowAttribute(hwnd, 33, ref corner, 4); // DWMWCP_ROUND
    }
    public static object Diagnostics(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        var region = CreateRoundRectRgn(0, 0, 1, 1, 0, 0);
        int regionType = GetWindowRgn(hwnd, region);
        bool cornerInRegion = PtInRegion(region, 0, 0);
        DeleteObject(region);
        return new { regionType, cornerInRegion, window.ShowInTaskbar };
    }
    public static Rect WorkArea(Window window)
    {
        var screen = System.Windows.Forms.Screen.FromHandle(new WindowInteropHelper(window).Handle);
        var scale = VisualTreeHelper.GetDpi(window);
        var r = screen.WorkingArea;
        return new(r.X / scale.DpiScaleX, r.Y / scale.DpiScaleY, r.Width / scale.DpiScaleX, r.Height / scale.DpiScaleY);
    }
    public static void Clamp(Window window)
    {
        var area = System.Windows.Forms.Screen.FromHandle(new WindowInteropHelper(window).Handle).WorkingArea;
        var bounds = Bounds(window);
        Move(window, new(Math.Clamp(bounds.X, area.Left, Math.Max(area.Left, area.Right - bounds.Width)),
            Math.Clamp(bounds.Y, area.Top, Math.Max(area.Top, area.Bottom - bounds.Height))));
    }
    public static Rect Bounds(Window window)
    {
        GetWindowRect(new WindowInteropHelper(window).Handle, out var r);
        return new(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
    }
    public static void Move(Window window, Point screenPixels)
    {
        var current = Bounds(window);
        int x = (int)Math.Round(screenPixels.X), y = (int)Math.Round(screenPixels.Y);
        if (current.X == x && current.Y == y) return;
        SetWindowPos(new WindowInteropHelper(window).Handle, 0, x, y, 0, 0, 0x0015); // NOSIZE | NOZORDER | NOACTIVATE
    }
    public static Point LogicalPosition(Window window)
    {
        var bounds = Bounds(window); var dpi = VisualTreeHelper.GetDpi(window);
        return new(bounds.X / dpi.DpiScaleX, bounds.Y / dpi.DpiScaleY);
    }
    public static void MoveLogical(Window window, Point position)
    {
        var dpi = VisualTreeHelper.GetDpi(window);
        Move(window, new(position.X * dpi.DpiScaleX, position.Y * dpi.DpiScaleY));
    }
    public static void Redraw(Window window) => RedrawWindow(new WindowInteropHelper(window).Handle, 0, 0, 0x0485); // invalidate, erase, children, frame
    public static bool IsForegroundWithin(params Window?[] windows)
    {
        // Native dialogs and WPF popups can own the foreground without their WPF
        // parent being active. Walk owners, but do not treat every process window
        // (or WPF's shared hidden taskbar owner) as part of this interaction.
        var handles = windows.Where(w => w != null).Select(w => new WindowInteropHelper(w!).Handle).Where(h => h != 0).ToHashSet();
        var foreground = GetForegroundWindow();
        if (foreground == 0) return false;
        for (var current = GetAncestor(foreground, 2); current != 0; current = GetWindow(current, 4)) // GA_ROOT, GW_OWNER
            if (handles.Contains(current)) return true;
        return false;
    }
    [StructLayout(LayoutKind.Sequential)] private struct PixelRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct Margins { public int Left, Right, Top, Bottom; }
    [DllImport("dwmapi")] private static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);
    [DllImport("dwmapi")] private static extern int DwmExtendFrameIntoClientArea(nint hwnd, ref Margins margins);
    [DllImport("gdi32")] private static extern nint CreateRoundRectRgn(int left, int top, int right, int bottom, int width, int height);
    [DllImport("gdi32")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PtInRegion(nint region, int x, int y);
    [DllImport("user32")] private static extern int GetWindowRgn(nint hwnd, nint region);
    [DllImport("user32")] private static extern bool GetWindowRect(nint hwnd, out PixelRect rect);
    [DllImport("user32")] private static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32")] private static extern bool RedrawWindow(nint hwnd, nint update, nint region, uint flags);
    [DllImport("user32")] private static extern nint GetForegroundWindow();
    [DllImport("user32")] private static extern nint GetAncestor(nint hwnd, uint flags);
    [DllImport("user32")] private static extern nint GetWindow(nint hwnd, uint command);
    [DllImport("gdi32")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeleteObject(nint obj);
    [DllImport("user32")] private static extern int SetWindowRgn(nint hwnd, nint region, [MarshalAs(UnmanagedType.Bool)] bool redraw);
}
