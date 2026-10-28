namespace Reimbursement.Core.Llm;

/// <summary>
/// 预设 LLM provider 列表（OpenAI 兼容协议，对应 Swift LLMProvider）。
/// 选 provider 自动填 base_url，留"自定义"给用户手输。
/// </summary>
public enum LlmProvider
{
    DeepSeek,
    OpenAI,
    Moonshot,
    Zhipu,
    Ollama,
    VLlm,
    Custom,
}

public static class LlmProviderInfo
{
    public static string DisplayName(this LlmProvider p) => p switch
    {
        LlmProvider.DeepSeek => "DeepSeek",
        LlmProvider.OpenAI => "OpenAI",
        LlmProvider.Moonshot => "月之暗面",
        LlmProvider.Zhipu => "智谱",
        LlmProvider.Ollama => "Ollama (本地)",
        LlmProvider.VLlm => "vLLM (自部署)",
        _ => "自定义",
    };

    public static string DefaultBaseUrl(this LlmProvider p) => p switch
    {
        LlmProvider.DeepSeek => "https://api.deepseek.com/v1",
        LlmProvider.OpenAI => "https://api.openai.com/v1",
        LlmProvider.Moonshot => "https://api.moonshot.cn/v1",
        LlmProvider.Zhipu => "https://open.bigmodel.cn/api/paas/v4",
        LlmProvider.Ollama => "http://localhost:11434/v1",
        LlmProvider.VLlm => "http://localhost:8000/v1",
        _ => "",
    };

    public static string DefaultModel(this LlmProvider p) => p switch
    {
        LlmProvider.DeepSeek => "deepseek-chat",
        LlmProvider.OpenAI => "gpt-4o-mini",
        LlmProvider.Moonshot => "moonshot-v1-8k",
        LlmProvider.Zhipu => "glm-4-flash",
        LlmProvider.Ollama => "qwen2.5:14b",
        LlmProvider.VLlm => "meta-llama/Meta-Llama-3-8B-Instruct",
        _ => "",
    };

    /// <summary>通过 baseURL 匹配 provider（用于启动时自动识别已存的配置）。</summary>
    public static LlmProvider Match(string baseUrl)
    {
        var s = baseUrl.ToLowerInvariant();
        if (s.Contains("deepseek")) return LlmProvider.DeepSeek;
        if (s.Contains("openai.com")) return LlmProvider.OpenAI;
        if (s.Contains("moonshot")) return LlmProvider.Moonshot;
        if (s.Contains("bigmodel") || s.Contains("zhipu")) return LlmProvider.Zhipu;
        if (s.Contains("11434")) return LlmProvider.Ollama;
        if (s.Contains(":8000") || s.Contains("vllm")) return LlmProvider.VLlm;
        return LlmProvider.Custom;
    }

    public static IEnumerable<LlmProvider> All => Enum.GetValues<LlmProvider>();
}
