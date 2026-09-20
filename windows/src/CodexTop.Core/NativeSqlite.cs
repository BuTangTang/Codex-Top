using System.Runtime.InteropServices;

namespace CodexTop.Core;

public sealed class NativeSqlite : IDisposable
{
    private nint db;
    public NativeSqlite(string path)
    {
        int result = sqlite3_open_v2(path, out db, 1 | 0x10000, null);
        if (result != 0) { Dispose(); throw new IOException("暂时无法读取 Codex 数据库，请检查数据目录或稍后刷新。"); }
        sqlite3_busy_timeout(db, 1000);
    }
    public List<Dictionary<string, string?>> Query(string sql)
    {
        if (sqlite3_prepare_v2(db, sql, -1, out var statement, 0) != 0) throw new InvalidDataException("Codex 数据格式不受支持，请检查版本。");
        try
        {
            var rows = new List<Dictionary<string, string?>>();
            var columns = Enumerable.Range(0, sqlite3_column_count(statement)).Select(i => Marshal.PtrToStringUTF8(sqlite3_column_name(statement, i))!).ToArray();
            int result;
            while ((result = sqlite3_step(statement)) == 100)
            {
                var row = new Dictionary<string, string?>();
                for (int i = 0; i < columns.Length; i++) row[columns[i]] = Marshal.PtrToStringUTF8(sqlite3_column_text(statement, i));
                rows.Add(row);
            }
            if (result != 101) throw new IOException("读取 Codex 数据库时发生错误，请稍后重试。");
            return rows;
        }
        finally { sqlite3_finalize(statement); }
    }
    public void Dispose() { if (db != 0) { sqlite3_close(db); db = 0; } }
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string name, out nint db, int flags, [MarshalAs(UnmanagedType.LPUTF8Str)] string? vfs);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_close(nint db);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_busy_timeout(nint db, int milliseconds);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_prepare_v2(nint db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, int bytes, out nint statement, nint tail);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_step(nint statement);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_finalize(nint statement);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_column_count(nint statement);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern nint sqlite3_column_name(nint statement, int index);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern nint sqlite3_column_text(nint statement, int index);
}
