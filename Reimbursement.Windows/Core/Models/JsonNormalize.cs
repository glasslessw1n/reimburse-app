using System.Globalization;
using System.Text.Json;

namespace Reimbursement.Core.Models;

/// <summary>
/// 把任意 JSON 值归一化为 string?（对应 Swift AnyJSONValue.toOptionalString）：
/// string 原样；number 整数不带小数点；bool 转 "true"/"false"；null/array/object 归 null。
/// </summary>
public static class JsonNormalize
{
    public static string? ToOptionalString(JsonElement el)
    {
        switch (el.ValueKind)
        {
            case JsonValueKind.String:
                return el.GetString();
            case JsonValueKind.Number:
                if (el.TryGetInt64(out var l)) return l.ToString(CultureInfo.InvariantCulture);
                var d = el.GetDouble();
                if (d == Math.Truncate(d) && Math.Abs(d) < 1e15)
                    return ((long)d).ToString(CultureInfo.InvariantCulture);
                return d.ToString(CultureInfo.InvariantCulture);
            case JsonValueKind.True:
                return "true";
            case JsonValueKind.False:
                return "false";
            default:
                return null;
        }
    }

    /// <summary>解析 fields 对象为 Dictionary&lt;string, string?&gt;（值经归一化）。</summary>
    public static Dictionary<string, string?> ParseFields(JsonElement obj)
    {
        var dict = new Dictionary<string, string?>();
        if (obj.ValueKind != JsonValueKind.Object) return dict;
        foreach (var prop in obj.EnumerateObject())
            dict[prop.Name] = ToOptionalString(prop.Value);
        return dict;
    }
}
