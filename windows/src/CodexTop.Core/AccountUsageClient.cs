using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace CodexTop.Core;

public sealed class AccountUsageClient
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private long lastAttempt;
    private string? lastRoot, lastCli;
    public QuotaSnapshot? Current { get; private set; }
    public string? Error { get; private set; }
    public async Task RefreshAsync(string root, string? cli, bool force, CancellationToken cancellation)
    {
        if (!await gate.WaitAsync(0, cancellation)) return;
        try
        {
            if (lastRoot != root || lastCli != cli) { lastAttempt = 0; Current = null; Error = null; lastRoot = root; lastCli = cli; }
            if (lastAttempt != 0 && Stopwatch.GetElapsedTime(lastAttempt).TotalSeconds < (force ? 5 : 60)) return;
            lastAttempt = Stopwatch.GetTimestamp();
            try { Current = await ReadAsync(root, cli, cancellation); Error = null; }
            catch (Exception e) when (e is IOException or InvalidDataException or System.ComponentModel.Win32Exception or OperationCanceledException)
            { Current = null; Error = e is OperationCanceledException ? "额度读取超时或已取消" : e.Message; }
        }
        finally { gate.Release(); }
    }
    public static string? FindCli()
    {
        foreach (var folder in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(folder)) continue;
            var candidate = Path.Combine(folder.Trim('"'), "codex.exe");
            if (File.Exists(candidate)) return candidate;
        }
        var bin = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenAI", "Codex", "bin");
        if (Directory.Exists(bin))
            return Directory.EnumerateDirectories(bin).Select(path => Path.Combine(path, "codex.exe")).Where(File.Exists).OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault();
        return null;
    }
    public static async Task<QuotaSnapshot> ReadAsync(string root, string? cli, CancellationToken cancellation)
    {
        cli ??= FindCli();
        if (cli is null || !File.Exists(cli)) throw new IOException("未找到 Codex CLI，请在设置中选择 codex.exe。");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(15)); var token = timeout.Token;
        var info = new ProcessStartInfo(cli) { RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true, StandardOutputEncoding = Encoding.UTF8 };
        info.ArgumentList.Add("app-server"); info.ArgumentList.Add("--stdio");
        info.Environment["CODEX_HOME"] = root;
        using var process = new Process { StartInfo = info };
        if (!process.Start()) throw new IOException("无法启动 Codex CLI。");
        var stderr = DrainAsync(process.StandardError, token);
        try
        {
            await SendAsync(process, new { id = 1, method = "initialize", @params = new { clientInfo = new { name = "codex_top_windows", title = "Codex Top for Windows", version = "0.1.0" } } }, token);
            var init = await ReadResponseAsync(process.StandardOutput, 1, token); init.Dispose();
            await SendAsync(process, new { method = "initialized", @params = new { } }, token);
            await SendAsync(process, new { id = 2, method = "account/rateLimits/read" }, token);
            using var response = await ReadResponseAsync(process.StandardOutput, 2, token);
            return Parse(response.RootElement.Field("result"), DateTimeOffset.UtcNow);
        }
        finally
        {
            timeout.Cancel();
            try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { }
            try { await process.WaitForExitAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(3)); } catch (TimeoutException) { }
            try { await stderr; } catch (OperationCanceledException) { }
        }
    }
    private static async Task SendAsync(Process process, object value, CancellationToken token)
    { await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(value).AsMemory(), token); await process.StandardInput.FlushAsync(token); }
    private static async Task DrainAsync(StreamReader reader, CancellationToken token)
    { var buffer = new char[4096]; while (await reader.ReadAsync(buffer, token) != 0) { } }
    private static async Task<JsonDocument> ReadResponseAsync(StreamReader reader, int id, CancellationToken token)
    {
        int total = 0; var line = new StringBuilder(); var buffer = new char[4096];
        while (true)
        {
            int count = await reader.ReadAsync(buffer.AsMemory(), token);
            if (count == 0) throw new IOException("Codex CLI 未返回额度，请确认已登录。");
            total += count;
            if (total > 1024 * 1024) throw new InvalidDataException("Codex CLI 返回的数据超过读取上限。");
            for (int i = 0; i < count; i++)
            {
                if (buffer[i] != '\n') { line.Append(buffer[i]); continue; }
                JsonDocument? message = null;
                try { message = JsonDocument.Parse(line.ToString()); } catch (JsonException) { }
                line.Clear();
                if (message == null) continue;
                if (message.RootElement.Field("id").TryGetInt32Safe(out int received) && received == id)
                {
                    if (message.RootElement.Field("error").ValueKind != JsonValueKind.Undefined)
                    { message.Dispose(); throw new IOException("账户额度暂时不可用，请确认 CLI 已登录并检查网络。"); }
                    return message;
                }
                message.Dispose();
            }
        }
    }
    public static QuotaSnapshot Parse(JsonElement result, DateTimeOffset at)
    {
        var mapping = result.Field("rateLimitsByLimitId");
        var limits = mapping.ValueKind == JsonValueKind.Object ? mapping.Field("codex") : result.Field("rateLimits");
        if (limits.ValueKind != JsonValueKind.Object || limits.Text("limitId") is { } id && id != "codex") throw new InvalidDataException("当前账户没有可用的 Codex 额度数据。");
        var windows = new List<QuotaWindow>();
        foreach (var name in new[] { "primary", "secondary" })
        {
            var window = limits.Field(name);
            if (window.Field("usedPercent").ValueKind != JsonValueKind.Number || !window.Field("usedPercent").TryGetDouble(out double used) || !double.IsFinite(used) ||
                !window.Field("windowDurationMins").TryGetInt32Safe(out int minutes) || minutes <= 0) continue;
            DateTimeOffset? reset = null;
            if (window.Field("resetsAt").ValueKind == JsonValueKind.Number && window.Field("resetsAt").TryGetInt64(out long unix) && unix >= 0 && unix <= 253402300799) reset = DateTimeOffset.FromUnixTimeSeconds(unix);
            windows.Add(new(minutes, used, reset));
        }
        if (windows.Count == 0) throw new InvalidDataException("账户未返回可显示的额度周期。");
        return new(windows, at);
    }
}

internal static class JsonNumber
{
    public static bool TryGetInt32Safe(this JsonElement e, out int value)
    { value = 0; return e.ValueKind == JsonValueKind.Number && e.TryGetInt32(out value); }
}
