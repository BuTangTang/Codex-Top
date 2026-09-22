using CodexTop.Core;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

internal static class LocalSourcePathChecks
{
    public static void Run(Action<string, Action> test, Action<bool, string> check)
    {
        foreach (bool extended in new[] { false, true })
            test($"local source reads {(extended ? "extended" : "ordinary")} paths and incremental completion", () =>
            {
                using var fixture = new Fixture();
                fixture.SetPath(extended ? Extended(fixture.Rollout) : fixture.Rollout);
                var source = new LocalCodexSource(fixture.Root);
                var first = source.Snapshot(["task"]);
                check(first.Warning == null && first.Tasks.Single().Activity.Phase == Phase.Running, "read running state");
                check(source.Snapshot(["task"]).BytesRead == 0, "unchanged record must not be replayed");
                fixture.Append("task_complete");
                var completed = source.Snapshot(["task"]);
                check(completed.Warning == null && completed.Tasks.Single().Activity.Phase == Phase.Completed, "read incremental completion");
            });
        test("extended selected root accepts ordinary rollout path", () =>
        {
            using var fixture = new Fixture();
            var snapshot = new LocalCodexSource(Extended(fixture.Root)).Snapshot(["task"]);
            check(snapshot.Warning == null && snapshot.Tasks.Single().Activity.Phase == Phase.Running, "root and record aliases must agree");
        });
        test("switching equivalent path spellings preserves incremental reader", () =>
        {
            using var fixture = new Fixture(); var source = new LocalCodexSource(fixture.Root);
            source.Snapshot(["task"]);
            fixture.SetPath(Extended(fixture.Rollout));
            check(source.Snapshot(["task"]).BytesRead == 0, "equivalent path must not reset reader");
            fixture.Append("task_complete");
            check(source.Snapshot(["task"]).Tasks.Single().Activity.Phase == Phase.Completed, "completion after alias switch");
        });
        test("ordinary and extended paths cannot escape to sibling or parent", () =>
        {
            using var fixture = new Fixture();
            var sibling = fixture.Root + "-other"; Directory.CreateDirectory(sibling);
            var outside = Path.Combine(sibling, "outside.jsonl"); File.Copy(fixture.Rollout, outside);
            foreach (var path in new[] { outside, Extended(outside), Extended(Path.Combine(fixture.Root, "..", "root-other", "outside.jsonl")) })
            {
                fixture.SetPath(path); Rejected(fixture, check);
            }
        });
        test("device namespaces remain unreadable", () =>
        {
            using var fixture = new Fixture();
            foreach (var path in new[] { @"\\.\" + fixture.Rollout, @"\\?\GLOBALROOT\Device\HarddiskVolume1\fixture.jsonl" })
            {
                fixture.SetPath(path); Rejected(fixture, check);
            }
        });
        test("junction within selected root accepts extended rollout", () =>
        {
            using var fixture = new Fixture();
            var link = Path.Combine(fixture.Root, "linked"); fixture.Junction(link, Path.GetDirectoryName(fixture.Rollout)!);
            fixture.SetPath(Extended(Path.Combine(link, "events.jsonl")));
            var snapshot = new LocalCodexSource(fixture.Root).Snapshot(["task"]);
            check(snapshot.Warning == null && snapshot.Tasks.Single().Activity.Phase == Phase.Running, "internal junction");
        });
        test("junction selected as data root remains readable", () =>
        {
            using var fixture = new Fixture();
            var link = Path.Combine(fixture.Base, "selected-link"); fixture.Junction(link, fixture.Root);
            fixture.SetPath(Extended(Path.Combine(link, "sessions", "events.jsonl")));
            var snapshot = new LocalCodexSource(link).Snapshot(["task"]);
            check(snapshot.Warning == null && snapshot.Tasks.Single().Activity.Phase == Phase.Running, "selected junction root");
        });
        test("ordinary and extended junction paths cannot leave selected root", () =>
        {
            using var fixture = new Fixture();
            var outside = Path.Combine(fixture.Base, "outside"); Directory.CreateDirectory(outside);
            File.Copy(fixture.Rollout, Path.Combine(outside, "events.jsonl"));
            var link = Path.Combine(fixture.Root, "escape"); fixture.Junction(link, outside);
            foreach (var path in new[] { Path.Combine(link, "events.jsonl"), Extended(Path.Combine(link, "events.jsonl")) })
            {
                fixture.SetPath(path); Rejected(fixture, check);
            }
        });
    }
    private static string Extended(string path) => @"\\?\" + path;
    private static void Rejected(Fixture fixture, Action<bool, string> check)
    {
        var snapshot = new LocalCodexSource(fixture.Root).Snapshot(["task"]);
        check(snapshot.BytesRead == 0 && snapshot.Warning != null && snapshot.Tasks.Single().Activity.Phase == Phase.Unknown, "outside record must remain unread and unknown");
    }
    private sealed class Fixture : IDisposable
    {
        public string Base { get; } = Path.Combine(Path.GetTempPath(), "CodexTop.SourcePathTests", Guid.NewGuid().ToString("N"));
        public string Root => Path.Combine(Base, "root");
        public string Rollout => Path.Combine(Root, "sessions", "events.jsonl");
        private readonly List<string> junctions = [];
        public Fixture()
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Rollout)!);
            Append("task_started");
            Execute("CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,cwd TEXT,rollout_path TEXT,created_at INTEGER,updated_at INTEGER,archived INTEGER);" +
                "INSERT INTO threads VALUES('task','Synthetic task','synthetic-project','',0,0,0);");
            SetPath(Rollout);
        }
        public void Append(string type) => File.AppendAllText(Rollout, JsonSerializer.Serialize(new { type = "event_msg", timestamp = DateTimeOffset.UtcNow, payload = new { type, turn_id = "synthetic-turn" } }) + "\n");
        public void SetPath(string path) => Execute("UPDATE threads SET rollout_path='" + path.Replace("'", "''") + "'");
        public void Junction(string link, string target)
        {
            // Fixtures only: junctions do not require the symlink privilege or Developer Mode.
            var start = new ProcessStartInfo("powershell.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            start.ArgumentList.Add("-NoProfile"); start.ArgumentList.Add("-NonInteractive"); start.ArgumentList.Add("-Command");
            start.ArgumentList.Add("$ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path $env:CODEXTOP_TEST_LINK -Target $env:CODEXTOP_TEST_TARGET | Out-Null");
            start.Environment["CODEXTOP_TEST_LINK"] = link; start.Environment["CODEXTOP_TEST_TARGET"] = target;
            using var process = Process.Start(start)!; process.WaitForExit();
            if (process.ExitCode != 0) throw new IOException("Cannot create synthetic junction fixture.");
            junctions.Add(link);
        }
        private void Execute(string sql)
        {
            int opened = sqlite3_open_v2(Path.Combine(Root, "state_5.sqlite"), out var db, 6, null);
            try
            {
                if (opened != 0) throw new IOException("Cannot open synthetic database.");
                if (sqlite3_exec(db, sql, 0, 0, out var error) != 0) { sqlite3_free(error); throw new IOException("Cannot write synthetic database."); }
            }
            finally { if (db != 0) sqlite3_close(db); }
        }
        public void Dispose()
        {
            var expectedParent = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "CodexTop.SourcePathTests"));
            var resolved = Path.GetFullPath(Base);
            if (!string.Equals(Path.GetDirectoryName(resolved), expectedParent, StringComparison.OrdinalIgnoreCase)) throw new IOException("Unexpected fixture cleanup path.");
            foreach (var link in junctions) Directory.Delete(link); // Remove links before recursive fixture cleanup.
            Directory.Delete(resolved, true);
        }
    }
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out nint db, int flags, string? vfs);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_exec(nint db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, nint callback, nint argument, out nint error);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_close(nint db);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern void sqlite3_free(nint pointer);
}
