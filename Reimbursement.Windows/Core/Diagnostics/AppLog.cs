namespace Reimbursement.Core.Diagnostics;

/// <summary>
/// 最小文件日志（评估 S4：全仓可观测性为零的止血）。
/// Core 不知道 %APPDATA% 在哪：由 App 层在启动时 Configure 到应用数据目录下的 logs/；
/// 未配置时静默丢弃（单元测试环境无副作用）。按天分文件，写入失败永不反噬业务。
/// </summary>
public static class AppLog
{
    private static readonly object Gate = new();
    private static string? _dir;

    public static void Configure(string directory)
    {
        lock (Gate) _dir = directory;
    }

    public static void Info(string category, string message) => Write("INFO", category, message);

    public static void Warn(string category, string message) => Write("WARN", category, message);

    public static void Error(string category, string message, Exception? ex = null) =>
        Write("ERROR", category, ex == null ? message : $"{message} :: {ex.GetType().Name}: {ex.Message}");

    private static void Write(string level, string category, string message)
    {
        try
        {
            string? dir;
            lock (Gate) dir = _dir;
            if (dir == null) return;
            Directory.CreateDirectory(dir);
            var line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss} [{level}] {category}: {message}\n";
            lock (Gate)
                File.AppendAllText(Path.Combine(dir, $"core-{DateTimeOffset.Now:yyyyMMdd}.log"), line);
        }
        catch { /* 日志永不抛错 */ }
    }
}
