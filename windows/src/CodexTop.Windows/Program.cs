using System.Windows.Threading;

namespace CodexTop.Windows;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        using var mutex = new Mutex(true, "Local\\CodexTop.Windows.Singleton", out bool created);
        using var restore = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\CodexTop.Windows.Restore");
        if (!created) { restore.Set(); return; }
        string? settingsDir = null, dataRoot = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--settings-dir" && i + 1 < args.Length) settingsDir = Path.GetFullPath(args[++i]);
            else if (args[i] == "--data-root" && i + 1 < args.Length) dataRoot = Path.GetFullPath(args[++i]);
        }
        var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        application.DispatcherUnhandledException += (_, e) =>
        {
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexTop", "last-error.txt");
            try { Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, DateTimeOffset.Now.ToString("O") + "\n" + e.Exception.GetType().Name + "\n" + e.Exception.StackTrace); } catch (IOException) { }
            System.Windows.MessageBox.Show("Codex Top 遇到错误，请重新启动。诊断记录已保存到应用数据目录。", "Codex Top", MessageBoxButton.OK, MessageBoxImage.Error);
            e.Handled = true; application.Shutdown(1);
        };
        var store = new MonitorStore(application.Dispatcher, settingsDir);
        if (dataRoot != null) { store.Preferences.CodexHome = dataRoot; store.ChangeSource(dataRoot, store.Preferences.CliPath); }
        var window = new MonitorWindow(store, args.Contains("--qa-window")); application.MainWindow = window;
        if (args.Contains("--show")) window.Loaded += (_, _) => window.RecoverWindow();
        var handle = ThreadPool.RegisterWaitForSingleObject(restore, (_, _) => application.Dispatcher.BeginInvoke(window.RecoverWindow), null, Timeout.Infinite, false);
        application.Exit += (_, _) => { handle.Unregister(null); store.Dispose(); };
        application.Run(window);
    }
}
