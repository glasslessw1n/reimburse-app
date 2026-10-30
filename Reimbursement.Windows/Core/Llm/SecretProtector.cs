using System.Security.Cryptography;
using System.Text;

namespace Reimbursement.Core.Llm;

/// <summary>
/// API Key 落盘保护（评估 L1 / 交付 P2-7）：Windows 上用 DPAPI（当前用户作用域）加密，
/// .env 里存 "dpapi:&lt;base64&gt;"；非 Windows（开发/测试）明文直通。
/// 读取兼容历史明文：无前缀的值原样返回，下一次 Save 时自动升级为密文。
/// 注意：密文与本机当前用户绑定，settings.env 拷到别的机器/用户下将无法解密（正是目的）；
/// 与 mac 版 .env 的明文互通也因此只保留"读明文"方向。
/// </summary>
public static class SecretProtector
{
    public const string Prefix = "dpapi:";

    public static string Protect(string plain)
    {
        if (string.IsNullOrEmpty(plain)) return plain;
        if (plain.StartsWith(Prefix, StringComparison.Ordinal)) return plain;
        if (!OperatingSystem.IsWindows()) return plain;
        try
        {
            var cipher = ProtectedData.Protect(
                Encoding.UTF8.GetBytes(plain), null, DataProtectionScope.CurrentUser);
            return Prefix + Convert.ToBase64String(cipher);
        }
        catch (Exception ex)
        {
            Diagnostics.AppLog.Error("settings", "DPAPI 加密失败，回退明文存储", ex);
            return plain;
        }
    }

    public static string Unprotect(string stored)
    {
        if (string.IsNullOrEmpty(stored)) return stored;
        if (!stored.StartsWith(Prefix, StringComparison.Ordinal)) return stored;
        if (!OperatingSystem.IsWindows()) return "";
        try
        {
            var plain = ProtectedData.Unprotect(
                Convert.FromBase64String(stored[Prefix.Length..]), null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plain);
        }
        catch (Exception ex)
        {
            // 换机/换用户/密文损坏：返回空而不是把密文当 Key 发出去，设置页会提示重新验证。
            Diagnostics.AppLog.Error("settings", "DPAPI 解密失败（可能换了机器或用户）", ex);
            return "";
        }
    }
}
