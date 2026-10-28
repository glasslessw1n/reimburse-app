using System.Text.Json;
using Reimbursement.Core.Llm;
using Xunit;

namespace Reimbursement.Core.Tests;

/// <summary>JSON 提取容错（由 Swift LLMClientTests 的 JSONParser 用例翻译）。</summary>
public class JsonObjectExtractorTests
{
    [Fact]
    public void ParsePlainJson()
    {
        var obj = JsonObjectExtractor.ExtractFirstJsonObject("""{"amount": 580, "receipt_type": "dining"}""");
        Assert.Equal("dining", obj.GetProperty("receipt_type").GetString());
        Assert.Equal(580, obj.GetProperty("amount").GetInt32());
    }

    [Fact]
    public void ParseFencedJson()
    {
        var obj = JsonObjectExtractor.ExtractFirstJsonObject("```json\n{\"receipt_type\": \"dining\"}\n```");
        Assert.Equal("dining", obj.GetProperty("receipt_type").GetString());
    }

    [Fact]
    public void ParseKeepsJsonSubstringInContent()
    {
        // 正文里含 "json" 子串不应被误删（Swift 版曾用 replacingOccurrences 误删，此为回归用例）
        var obj = JsonObjectExtractor.ExtractFirstJsonObject("```json\n{\"note\": \"myjsonvalue\", \"amount\": 5}\n```");
        Assert.Equal("myjsonvalue", obj.GetProperty("note").GetString());
    }

    [Fact]
    public void ParseNestedBracesWithSurroundingText()
    {
        var obj = JsonObjectExtractor.ExtractFirstJsonObject("前缀说明 {\"items\": [{\"name\": \"a\"}], \"amount\": 10} 后缀说明");
        Assert.Equal(10, obj.GetProperty("amount").GetInt32());
    }

    [Fact]
    public void ParseBracesInsideStringLiteral()
    {
        // 本实现的改进点：字符串内的 } 与转义引号不应截断括号匹配（Swift 版括号计数会截错）
        var obj = JsonObjectExtractor.ExtractFirstJsonObject("""{"note": "a}b\"c", "amount": 7}""");
        Assert.Equal("a}b\"c", obj.GetProperty("note").GetString());
        Assert.Equal(7, obj.GetProperty("amount").GetInt32());
    }
}
