using System.Globalization;

namespace Reimbursement.Core.Llm;

/// <summary>LLM 及报销主数据设置（对应 Swift LLMSettings）。</summary>
public sealed class LlmSettings
{
    public string ApiKey { get; set; } = "";
    public string BaseUrl { get; set; } = "https://api.openai.com/v1";
    public string Model { get; set; } = "gpt-4o-mini";
    public double TimeoutSeconds { get; set; } = 60;

    /// <summary>购方主数据（与 Swift 版现状一致：只存盘，识别后校验为后续改进项，见分析报告 §7）。</summary>
    public string BuyerName { get; set; } = "";
    public string BuyerTaxNo { get; set; } = "";

    /// <summary>行程分组用的"常驻地"列表（行程名里要去掉的城市）。</summary>
    public List<string> ExcludeCities { get; set; } = new();

    /// <summary>常驻地集合（trim+小写、去空，供 TripResolver 切分用）。</summary>
    public HashSet<string> HomeCities => new(
        ExcludeCities.Select(c => c.Trim().ToLowerInvariant()).Where(c => c.Length > 0));

    public LlmConfig ToConfig() => new(ApiKey, BaseUrl, Model, TimeoutSeconds);
}

/// <summary>
/// .env 配置持久化（对应 Swift LLMSettingsStore / Python settings.py）：
/// 手解析 KEY=VALUE，支持 export 前缀、引号、行尾 # 注释。文件位置由调用方给定
/// （mac 版为 ~/Library/Application Support/Reimbursement/.env；Windows 版将用 %APPDATA%\Reimbursement\.env）。
/// </summary>
public sealed class LlmSettingsStore
{
    private readonly string _envPath;

    public LlmSettings Settings { get; private set; }

    public LlmSettingsStore(string envPath)
    {
        _envPath = envPath;
        Settings = Load(envPath);
    }

    public static LlmSettings Load(string envPath)
    {
        var s = new LlmSettings();
        if (!File.Exists(envPath)) return s;
        var raw = File.ReadAllText(envPath);
        foreach (var (key, value) in ParseEnv(raw))
        {
            switch (key)
            {
                case "LLM_API_KEY": s.ApiKey = value; break;
                case "LLM_BASE_URL":
                    if (Uri.TryCreate(value, UriKind.Absolute, out _)) s.BaseUrl = value;
                    break;
                case "LLM_MODEL": s.Model = value; break;
                case "LLM_TIMEOUT":
                    if (double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var t))
                        s.TimeoutSeconds = t;
                    break;
                case "BUYER_NAME": s.BuyerName = value; break;
                case "BUYER_TAX_NO": s.BuyerTaxNo = value; break;
                case "EXCLUDE_CITIES":
                    s.ExcludeCities = value.Split(',', StringSplitOptions.RemoveEmptyEntries)
                        .Select(x => x.Trim()).ToList();
                    break;
            }
        }
        return s;
    }

    /// <summary>存盘到 .env（固定键序，与 Swift save() 的输出格式一致）。</summary>
    public void Save()
    {
        var dir = Path.GetDirectoryName(_envPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var lines = new List<string>
        {
            "# 报销整理 LLM 配置",
            $"LLM_API_KEY={Settings.ApiKey}",
            $"LLM_BASE_URL={Settings.BaseUrl}",
            $"LLM_MODEL={Settings.Model}",
            $"LLM_TIMEOUT={(int)Settings.TimeoutSeconds}",
        };
        if (Settings.BuyerName.Length > 0) lines.Add($"BUYER_NAME={Settings.BuyerName}");
        if (Settings.BuyerTaxNo.Length > 0) lines.Add($"BUYER_TAX_NO={Settings.BuyerTaxNo}");
        if (Settings.ExcludeCities.Count > 0)
            lines.Add($"EXCLUDE_CITIES={string.Join(",", Settings.ExcludeCities)}");
        File.WriteAllText(_envPath, string.Join("\n", lines) + "\n");
    }

    /// <summary>解析 .env 文本：支持 # 注释、空行、`export ` 前缀、引号包裹、行尾 " #" 注释（与 Swift parseEnv 逐条对应）。</summary>
    public static List<(string Key, string Value)> ParseEnv(string text)
    {
        var result = new List<(string, string)>();
        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            if (line.StartsWith("export ", StringComparison.Ordinal))
                line = line["export ".Length..].Trim();
            var eq = line.IndexOf('=');
            if (eq < 0) continue;
            var key = line[..eq].Trim();
            var value = line[(eq + 1)..].Trim();

            // 去掉引号（首尾同种引号且长度 ≥2）
            if (value.Length >= 2 &&
                ((value.StartsWith('"') && value.EndsWith('"')) ||
                 (value.StartsWith('\'') && value.EndsWith('\''))))
            {
                value = value[1..^1];
            }

            // 去掉尾部 # 注释（不在引号内的 " #"）
            if (!value.StartsWith('"') && !value.StartsWith('\''))
            {
                var hashPos = value.IndexOf(" #", StringComparison.Ordinal);
                if (hashPos >= 0) value = value[..hashPos].Trim();
            }
            result.Add((key, value));
        }
        return result;
    }
}
