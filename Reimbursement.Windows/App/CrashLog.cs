namespace Reimbursement.App;

/// <summary>
/// 启动面包屑 + 未处理异常落盘（%APPDATA%\Reimbursement.Windows\startup.log）。
/// 非打包 WinUI 应用闪退时默认无任何提示，靠这个文件定位死在哪一步：
/// 若日志里连 "App ctor start" 都没有，问题在托管代码运行之前的运行时/引导层；
/// 若停在某个面包屑之后，则死在下一步。
/// </summary>
internal static class CrashLog
{
    private static readonly string LogPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "Reimbursement.Windows", "startup.log");

    public static void Write(string message)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            File.AppendAllText(LogPath,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}\n");
        }
        catch
        {
            // 日志失败不许影响启动
        }
    }

    public static void WriteException(string where, Exception ex) =>
        Write($"{where} EXCEPTION: {ex}");
}
