using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CodexTop.Core;

public sealed class IncrementalRollout
{
    public const int ChunkSize = 65536;
    public const int ScanBudget = 4 * 1024 * 1024;
    public RolloutReducer Reducer { get; private set; } = new();
    public long Offset { get; private set; }
    public bool CaughtUp { get; private set; }
    public int PendingBytes => pending.Count;
    private readonly List<byte> pending = [];
    private bool dropping;
    private long observedSize = -1;
    private long observedWrite;
    private string? identity;
    private bool recoveryFinished;
    private long recoverySearch = -1;
    private long replayOffset = -1;
    private RolloutReducer? recovery;
    private readonly List<byte> recoveryPending = [];
    private bool recoveryDropping;
    public long Refresh(string path, int budget = ScanBudget)
    {
        using var stream = Open(path);
        var info = Describe(stream);
        if (identity != info.Id || info.Size < observedSize || info.Size == observedSize && info.Write != observedWrite)
        {
            Reducer = new(); pending.Clear(); dropping = false; Offset = Math.Max(0, info.Size - ChunkSize);
            recoveryFinished = false; recoverySearch = -1; replayOffset = -1; recovery = null; recoveryPending.Clear(); recoveryDropping = false;
            if (Offset > 0) dropping = true;
        }
        identity = info.Id; observedSize = info.Size; observedWrite = info.Write;
        stream.Position = Offset;
        var buffer = new byte[ChunkSize]; long bytes = 0;
        while (stream.Position < info.Size && bytes < budget)
        {
            int count = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, Math.Min(info.Size - stream.Position, budget - bytes)));
            if (count == 0) break;
            Feed(Reducer, buffer.AsSpan(0, count), pending, ref dropping);
            Offset += count; bytes += count;
        }
        CaughtUp = Offset >= info.Size;
        if (Reducer.Activity.StartedAt != null) { recoveryFinished = true; recovery = null; recoveryPending.Clear(); }
        return bytes;
    }
    public long RecoverTiming(string path, int budget = ScanBudget)
    {
        if (recoveryFinished || !CaughtUp || Reducer.Activity.StartedAt != null || !Reducer.Activity.Phase.IsActive()) return 0;
        using var stream = Open(path);
        var info = Describe(stream);
        if (info.Id != identity || info.Size != observedSize || info.Write != observedWrite) return 0;
        long bytes = 0;
        if (recoverySearch < 0) recoverySearch = Offset;
        var buffer = new byte[ChunkSize];
        while (replayOffset < 0 && recoverySearch > 0 && bytes < budget)
        {
            // Overlap one line to locate a complete start record at block boundaries.
            long end = recoverySearch; long begin = Math.Max(0, end - ChunkSize);
            stream.Position = begin;
            int size = (int)Math.Min(2 * ChunkSize, Math.Min(Offset - begin, budget - bytes));
            if (size <= 0) break;
            var search = new byte[size]; int read = stream.Read(search); bytes += read;
            int from = begin == 0 ? 0 : Array.IndexOf(search, (byte)'\n', 0, read) + 1;
            long? latestStart = null;
            for (int i = from; from >= 0 && i < read; i++)
            {
                if (search[i] != 10) continue;
                if (i - from <= ChunkSize)
                {
                    try
                    {
                        using var doc = System.Text.Json.JsonDocument.Parse(search.AsMemory(from, i - from));
                        if (doc.RootElement.Text("type") == "event_msg" && doc.RootElement.Field("payload").Text("type") is "task_started" or "turn_started") latestStart = begin + from;
                    }
                    catch (System.Text.Json.JsonException) { }
                }
                from = i + 1;
            }
            recoverySearch = begin;
            if (latestStart is { } found) { replayOffset = found; recovery = new(); }
        }
        if (replayOffset < 0) { if (recoverySearch == 0) recoveryFinished = true; return bytes; }
        stream.Position = replayOffset;
        while (replayOffset < Offset && bytes < budget)
        {
            int count = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, Math.Min(Offset - replayOffset, budget - bytes)));
            if (count == 0) break;
            Feed(recovery!, buffer.AsSpan(0, count), recoveryPending, ref recoveryDropping);
            replayOffset += count; bytes += count;
        }
        var after = Describe(stream);
        if (replayOffset >= Offset && info == after)
        { Reducer.RecoverTiming(recovery!.Activity); recoveryFinished = true; recovery = null; recoveryPending.Clear(); }
        return bytes;
    }
    private static void Feed(RolloutReducer reducer, ReadOnlySpan<byte> bytes, List<byte> tail, ref bool skip)
    {
        foreach (byte value in bytes)
        {
            if (value == 10)
            {
                if (!skip && tail.Count > 0) reducer.Consume(CollectionsMarshal.AsSpan(tail));
                tail.Clear(); skip = false;
            }
            else if (!skip)
            {
                if (tail.Count >= ChunkSize) { tail.Clear(); skip = true; }
                else tail.Add(value);
            }
        }
    }
    private static FileStream Open(string path) => new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, ChunkSize, FileOptions.SequentialScan);
    private static (string Id, long Size, long Write) Describe(FileStream stream)
    {
        if (!GetFileInformationByHandle(stream.SafeFileHandle, out var info)) throw new IOException("无法读取任务文件信息。");
        return ($"{info.Volume:X8}:{info.IndexHigh:X8}:{info.IndexLow:X8}", ((long)info.SizeHigh << 32) | info.SizeLow, ((long)info.WriteHigh << 32) | info.WriteLow);
    }
    [StructLayout(LayoutKind.Sequential)] private struct FileInformation
    {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation info);
}
