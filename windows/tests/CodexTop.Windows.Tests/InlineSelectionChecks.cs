using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using CodexTop.Core;
using CodexTop.Windows;
using Application = System.Windows.Application;
using Button = System.Windows.Controls.Button;
using CheckBox = System.Windows.Controls.CheckBox;

internal static class InlineSelectionChecks
{
    public static int Run(string fixtureSettings)
    {
        string directory = Path.Combine(Path.GetTempPath(), "CodexTop.InlineChecks", Guid.NewGuid().ToString("N"));
        var file = new PreferencesFile(Path.Combine(directory, "settings.json"));
        var preferences = new PreferencesFile(fixtureSettings).Load();
        preferences.CliPath = Path.Combine(directory, "disabled-cli.exe");
        preferences.Placement = Placement.Floating; preferences.Dark = false; file.Save(preferences);
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        using var store = new MonitorStore(app.Dispatcher, directory);
        var window = new MonitorWindow(store);
        int checks = 0, failures = 0;
        void Check(bool condition, string name) { checks++; if (!condition) { failures++; Console.WriteLine("FAIL " + name); } }
        void Press(Button button) => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Button Named(Window target, string name) => Descendants(target).OfType<Button>().First(b => AutomationProperties.GetName(b) == name);
        CheckBox Choice(Window target, string title) => Descendants(target).OfType<CheckBox>().Single(b => AutomationProperties.GetName(b) == title);
        void Remove(string id) => Press(Descendants(window).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "unfollow-" + id));
        window.Loaded += async (_, _) =>
        {
            try
            {
                var deadline = DateTime.UtcNow.AddSeconds(5);
                while (store.Loading && DateTime.UtcNow < deadline) await Task.Delay(50);
                Check(store.Tasks.Count == 6, "synthetic data source loaded");
                Press(Named(window, "展开或收起已结束任务"));
                var completed = store.Rows.First(r => r.Activity.Phase == Phase.Completed).Root;
                var running = store.Rows.First(r => r.Activity.Phase == Phase.Running).Root;
                var picker = new TaskPickerWindow(store); picker.Show(); window.UpdateLayout(); picker.UpdateLayout();
                Choice(picker, running.Title).IsChecked = false;
                Remove(completed.Id); picker.UpdateLayout();
                Check(!store.Preferences.SelectedIds.Contains(completed.Id), "completed row removed immediately");
                Check(store.Preferences.ExcludedIds.Contains(completed.Id), "inline removal persists a manual exclusion");
                Check(store.Tasks.Count == 6, "underlying tasks remain intact");
                Check(Choice(picker, completed.Title).IsChecked == false, "open picker reflects external removal");
                Check(Choice(picker, running.Title).IsChecked == false, "open picker preserves uncommitted edit");
                Check(store.Preferences.SelectedIds.Contains(running.Id), "draft edit has not been committed early");
                Press(Named(picker, "应用选择"));
                var saved = file.Load();
                Check(!saved.SelectedIds.Contains(completed.Id) && !saved.SelectedIds.Contains(running.Id), "picker apply and persisted settings preserve both removals");
                Check(saved.ExcludedIds.Contains(running.Id), "picker removal still uses exclusion policy");
                // Simulate another automatic reconciliation using the real policy.
                saved.AutoMonitor = true; saved.AutoEnabledAt = completed.CreatedAt.AddSeconds(-1); saved.BaselineIds.Clear();
                MonitoringPolicy.Reconcile(saved, store.Tasks, store.Graph, DateTimeOffset.UtcNow);
                Check(!saved.SelectedIds.Contains(completed.Id), "auto monitoring cannot re-add inline exclusion");
                picker = new TaskPickerWindow(store); picker.Show(); picker.UpdateLayout();
                Choice(picker, completed.Title).IsChecked = true; Press(Named(picker, "应用选择"));
                Check(store.Preferences.SelectedIds.Contains(completed.Id) && !store.Preferences.ExcludedIds.Contains(completed.Id), "task can be selected again through plus");
                foreach (string id in store.Preferences.SelectedIds.ToArray()) { window.UpdateLayout(); Remove(id); }
                window.UpdateLayout();
                Check(store.Rows.Count == 0, "last removal produces empty state");
                Check(!Descendants(window).OfType<Button>().Any(b => AutomationProperties.GetAutomationId(b).StartsWith("unfollow-")), "empty list has no stale removal actions");
                Check(Descendants(window).OfType<Button>().Any(b => AutomationProperties.GetName(b) == "选择关注任务"), "empty state can still open task selection");
            }
            catch (Exception error) { failures++; Console.WriteLine(error); }
            finally
            {
                foreach (var dialog in app.Windows.OfType<TaskPickerWindow>().ToArray()) dialog.Close();
                store.Preferences.SelectedIds = preferences.SelectedIds.ToHashSet(); store.Preferences.ExcludedIds.Clear(); store.Save();
                window.Title = "Codex Top · 行内取消检查"; window.ShowInTaskbar = true;
                Console.WriteLine($"Inline selection checks: {checks}, failures: {failures}. Settings: {directory}");
            }
        };
        app.Run(window); return failures == 0 ? 0 : 1;
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i); yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
