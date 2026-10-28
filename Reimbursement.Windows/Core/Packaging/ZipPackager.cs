using System.IO.Compression;
using Reimbursement.Core.Models;
using Reimbursement.Core.Storage;

namespace Reimbursement.Core.Packaging;

/// <summary>
/// 把 session 的 trips/ 打成 ZIP（对应 Swift ZipPackager / Python package_to_file）。
/// 与 mac 版的区别：不调外部 ditto，进程内用 System.IO.Compression 生成（ZIP 条目名 UTF-8，中文不乱码）。
/// ZIP 结构：报销单据{yyyy-MM-dd-HHmmss}/[报销明细.xlsx]/&lt;行程目录&gt;/&lt;文件&gt;…（不含 manifest/originals）。
/// </summary>
public static class ZipPackager
{
    public sealed class PackageException : Exception
    {
        public enum Kind { SessionNotFound, TripsDirMissing, ZipFailed }
        public Kind ErrorKind { get; }
        public PackageException(Kind kind, string message) : base(message) => ErrorKind = kind;
    }

    /// <summary>
    /// 打包并返回 ZIP 路径（不删除 session 目录）。
    /// downloadsDir 由调用方用 Known Folder API 取得（Windows 版不要写死 %USERPROFILE%\Downloads）。
    /// excelWriter：可选回调，参数为 staging 内的 xlsx 目标路径（通常接 ExcelBuilder.Build）；生成失败只记 stderr 不中断打包（与 Swift 版一致）。
    /// </summary>
    public static string Package(SessionManager session, string downloadsDir,
        bool includeExcel = true, IReadOnlySet<string>? homeCities = null,
        Action<string>? excelWriter = null)
    {
        var root = session.RootDir;
        if (!Directory.Exists(root))
            throw new PackageException(PackageException.Kind.SessionNotFound, "会话目录不存在");

        var tripsDir = Path.Combine(root, "trips");
        if (!Directory.Exists(tripsDir))
            throw new PackageException(PackageException.Kind.TripsDirMissing, "行程目录未生成，请先完成整理");

        var timestamp = DateTime.Now.ToString("yyyy-MM-dd-HHmmss");
        var zipFolderName = $"报销单据{timestamp}";
        Directory.CreateDirectory(downloadsDir);
        var zipPath = Path.Combine(downloadsDir, $"{zipFolderName}.zip");

        var stagingRoot = Path.Combine(Path.GetTempPath(), $"reimburse-staging-{Guid.NewGuid()}");
        var stagingFolder = Path.Combine(stagingRoot, zipFolderName);
        try
        {
            Directory.CreateDirectory(stagingFolder);
            foreach (var src in Directory.EnumerateFileSystemEntries(tripsDir))
            {
                var dst = Path.Combine(stagingFolder, Path.GetFileName(src));
                CopyRecursive(src, dst);
            }
            if (includeExcel && excelWriter != null)
            {
                try
                {
                    excelWriter(Path.Combine(stagingFolder, "报销明细.xlsx"));
                }
                catch (Exception e)
                {
                    Console.Error.WriteLine($"[ZipPackager] Excel 生成失败: {e.Message}");
                }
            }
        }
        catch (Exception e)
        {
            TryDeleteDir(stagingRoot);
            throw new PackageException(PackageException.Kind.ZipFailed, $"打包失败：staging 失败：{e.Message}");
        }

        try
        {
            if (File.Exists(zipPath)) File.Delete(zipPath);
            ZipFile.CreateFromDirectory(stagingRoot, zipPath, CompressionLevel.Optimal, includeBaseDirectory: false);
        }
        catch (Exception e)
        {
            throw new PackageException(PackageException.Kind.ZipFailed, $"打包失败：{e.Message}");
        }
        finally
        {
            TryDeleteDir(stagingRoot);
        }
        return zipPath;
    }

    /// <summary>
    /// finalize 之后把 bills **复制**到 trips/{dirname}/{targetFilename}。
    /// 幂等：先清掉上次的 trips/ 再从 originals 复制，originals 全程不动，可重复打包。
    /// 同名冲突后缀从 B 起（B…Z 后转 _1、_2…）；优先用 finalTargetName，否则现算 BuildFilename。
    /// </summary>
    public static void ArrangeFiles(SessionManager session)
    {
        var root = session.RootDir;
        var originals = Path.Combine(root, "originals");
        var tripsDir = Path.Combine(root, "trips");
        if (Directory.Exists(tripsDir)) Directory.Delete(tripsDir, recursive: true);
        Directory.CreateDirectory(tripsDir);

        foreach (var trip in session.Manifest.Trips)
        {
            var sub = Path.Combine(tripsDir, trip.Dirname);
            Directory.CreateDirectory(sub);
            foreach (var bill in trip.Bills)
                CopyBill(bill, originals, sub);
        }

        // 本地：只在有票据时才建目录
        if (session.Manifest.Local.Count > 0)
        {
            var localDir = Path.Combine(tripsDir, "本地");
            Directory.CreateDirectory(localDir);
            foreach (var bill in session.Manifest.Local)
                CopyBill(bill, originals, localDir);
        }
    }

    private static void CopyBill(BillInfo bill, string originals, string sub)
    {
        var src = Path.Combine(originals, bill.SourceFile);
        if (!File.Exists(src)) return;

        var newName = bill.FinalTargetName.Length > 0
            ? bill.FinalTargetName
            : SessionManager.BuildFilename(bill);
        var ext = Path.GetExtension(newName); // 含点，如 ".pdf"
        var baseName = ext.Length > 0 ? newName[..^ext.Length] : newName;

        var finalName = newName;
        var suffix = 2;
        while (File.Exists(Path.Combine(sub, finalName)))
        {
            finalName = suffix <= 26
                ? $"{baseName}{(char)(64 + suffix)}{ext}"
                : $"{baseName}_{suffix - 26}{ext}";
            suffix++;
        }
        File.Copy(src, Path.Combine(sub, finalName));
    }

    private static void CopyRecursive(string src, string dst)
    {
        if (File.Exists(src))
        {
            File.Copy(src, dst, overwrite: true);
            return;
        }
        Directory.CreateDirectory(dst);
        foreach (var entry in Directory.EnumerateFileSystemEntries(src))
            CopyRecursive(entry, Path.Combine(dst, Path.GetFileName(entry)));
    }

    private static void TryDeleteDir(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true); }
        catch (Exception) { /* 临时目录清理失败不致命 */ }
    }
}
