using Reimbursement.Core.Models;
using Xunit;

namespace Reimbursement.Core.Tests;

/// <summary>Receipt 必填字段覆盖度（由 Swift ReceiptTests 翻译）：显式 null 不算命中。</summary>
public class ReceiptTests
{
    [Fact]
    public void RequiredCoverageTreatsNullAsMissing()
    {
        var r = new Receipt(BillType.Dining)
        {
            Fields = new Dictionary<string, string?> { ["amount"] = null, ["issue_date"] = null },
        };
        Assert.Equal(0, r.RequiredCoverage);
    }

    [Fact]
    public void RequiredCoverageFullHit()
    {
        var r = new Receipt(BillType.Dining)
        {
            Fields = new Dictionary<string, string?> { ["amount"] = "580", ["issue_date"] = "2026-09-16" },
        };
        Assert.Equal(1, r.RequiredCoverage);
    }

    [Fact]
    public void RequiredCoveragePartial()
    {
        var r = new Receipt(BillType.Dining)
        {
            Fields = new Dictionary<string, string?> { ["amount"] = "580", ["issue_date"] = null },
        };
        Assert.Equal(0.5, r.RequiredCoverage);
    }

    [Fact]
    public void RequiredCoverageNoRequiredFieldsIsFull()
    {
        var r = new Receipt(BillType.Other);
        Assert.Equal(1, r.RequiredCoverage);
    }
}
