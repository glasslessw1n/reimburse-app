using System.Text.Json;

namespace Reimbursement.Core.Llm;

/// <summary>
/// 从 LLM 输出文本里提取第一个 JSON 对象（对应 Swift JSONParser，并作一处有意改进）：
/// 1. 整体直解；2. 剥 ``` 代码围栏后解；3. 从第一个 { 起做括号匹配截取后解。
/// 改进点：Swift 版的括号计数不感知字符串内容，字符串里的 } 或转义引号会截错；
/// 本实现用状态机跟踪字符串与转义，且候选解失败时继续从下一个 { 重试。
/// </summary>
public static class JsonObjectExtractor
{
    /// <summary>提取并返回第一个 JSON 对象（JsonElement，已 Clone 脱离文档生命周期）。找不到时抛 JsonException。</summary>
    public static JsonElement ExtractFirstJsonObject(string text)
    {
        // 1. 整体直解
        if (TryParseObject(text.Trim(), out var el)) return el;

        // 2. 代码围栏：取第一对 ``` 之间的内容（跳过语言标记行）
        var fenceStart = text.IndexOf("```", StringComparison.Ordinal);
        if (fenceStart >= 0)
        {
            var contentStart = text.IndexOf('\n', fenceStart);
            if (contentStart >= 0)
            {
                var fenceEnd = text.IndexOf("```", contentStart, StringComparison.Ordinal);
                var inner = fenceEnd >= 0
                    ? text[(contentStart + 1)..fenceEnd]
                    : text[(contentStart + 1)..];
                if (TryParseObject(inner.Trim(), out el)) return el;
            }
        }

        // 3. 扫描 { 做字符串感知的括号匹配
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] != '{') continue;
            var end = MatchBrace(text, i);
            if (end < 0) continue;
            if (TryParseObject(text[i..(end + 1)], out el)) return el;
        }

        throw new JsonException("未在文本中找到合法的 JSON 对象");
    }

    private static bool TryParseObject(string s, out JsonElement result)
    {
        result = default;
        if (s.Length == 0 || s[0] != '{') return false;
        try
        {
            using var doc = JsonDocument.Parse(s);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return false;
            result = doc.RootElement.Clone();
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    /// <summary>从 start 处的 { 开始，返回配对 } 的下标；跟踪字符串字面量与反斜杠转义；不配对返回 -1。</summary>
    private static int MatchBrace(string text, int start)
    {
        var depth = 0;
        var inString = false;
        var escaped = false;
        for (var i = start; i < text.Length; i++)
        {
            var ch = text[i];
            if (inString)
            {
                if (escaped) escaped = false;
                else if (ch == '\\') escaped = true;
                else if (ch == '"') inString = false;
                continue;
            }
            switch (ch)
            {
                case '"': inString = true; break;
                case '{': depth++; break;
                case '}':
                    depth--;
                    if (depth == 0) return i;
                    break;
            }
        }
        return -1;
    }
}
