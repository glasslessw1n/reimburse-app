using Reimbursement.Core.Llm;
using Reimbursement.Core.Models;
using Reimbursement.Core.Storage;
using Xunit;

namespace Reimbursement.Core.Tests;

/// <summary>
/// 评估 S2/S3/M3 的回归网：manifest 单一事实源（Bills 为准、Trips/Local 派生）、
/// 损坏清单改名备份、schema_version 落盘、密钥保护往返。
/// </summary>
public class ManifestStateTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "reimburse-state-" + Guid.NewGuid().ToString("N"));
    private readonly string _sessionsRoot;
    private readonly string _sid = Sessions.CreateNewSid();

    public ManifestStateTests() => _sessionsRoot = Path.Combine(_root, "sessions");

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    private SessionManager BuildFinalizedSession()
    {
        var session = new SessionManager(_sessionsRoot, _sid);
        BillInfo Make(BillType t, double amt, string src, Dictionary<string, string?> fields)
        {
            session.SaveOriginal(new byte[] { 1, 2, 3 }, src);
            return new BillInfo(t, amt, src, fields);
        }
        session.Ingest(Make(BillType.BoardingPass, 800, "bp1.pdf", new()
        {
            ["departure_date"] = "2026-09-10", ["origin_city"] = "重庆", ["destination_city"] = "厦门",
        }));
        session.Ingest(Make(BillType.HotelFolio, 1200, "folio.pdf", new()
        {
            ["hotel_name"] = "厦门某酒店", ["check_in_date"] = "2026-09-10",
            ["check_out_date"] = "2026-09-12", ["city"] = "厦门",
        }));
        session.Ingest(Make(BillType.BoardingPass, 820, "bp2.pdf", new()
        {
            ["departure_date"] = "2026-09-12", ["origin_city"] = "厦门", ["destination_city"] = "重庆",
        }));
        session.Finalize(new HashSet<string> { "重庆" });
        return session;
    }

    [Fact]
    public void RemovedBillNeverResurrectsAfterReload()
    {
        var session = BuildFinalizedSession();
        var victim = session.Manifest.Bills.First(b => b.BillType == BillType.HotelFolio);
        session.RemoveBill(victim.Uid);

        // 内存中派生视图已同步
        Assert.DoesNotContain(session.Manifest.Trips.SelectMany(t => t.Bills), b => b.Uid == victim.Uid);
        // 落盘重读后依然不存在（旧实现读盘上 Trips 副本会复活）
        var reloaded = new SessionManager(_sessionsRoot, _sid);
        Assert.Equal(2, reloaded.Manifest.Bills.Count);
        Assert.DoesNotContain(reloaded.Manifest.Trips.SelectMany(t => t.Bills), b => b.Uid == victim.Uid);
        Assert.DoesNotContain(reloaded.Manifest.Local, b => b.Uid == victim.Uid);
    }

    [Fact]
    public void TamperedDerivedCopiesHealOnLoad()
    {
        var session = BuildFinalizedSession();
        var victim = session.Manifest.Bills.First(b => b.BillType == BillType.HotelFolio);
        session.RemoveBill(victim.Uid);

        // 人为把已删票据塞回盘上的 trips 副本，模拟历史分叉数据
        var manifestPath = Path.Combine(session.RootDir, "manifest.json");
        var json = File.ReadAllText(manifestPath);
        var manifest = System.Text.Json.JsonSerializer.Deserialize<SessionManifest>(json, ReimburseJson.Options)!;
        manifest.Trips[0].Bills.Add(victim);
        File.WriteAllText(manifestPath, System.Text.Json.JsonSerializer.Serialize(manifest, ReimburseJson.Options));

        var reloaded = new SessionManager(_sessionsRoot, _sid);
        Assert.DoesNotContain(reloaded.Manifest.Trips.SelectMany(t => t.Bills), b => b.Uid == victim.Uid);
    }

    [Fact]
    public void CorruptManifestIsBackedUpNotDestroyed()
    {
        var session = new SessionManager(_sessionsRoot, _sid);
        var manifestPath = Path.Combine(session.RootDir, "manifest.json");
        File.WriteAllText(manifestPath, "{ this is not json !!!");

        var recovered = new SessionManager(_sessionsRoot, _sid);
        Assert.True(recovered.RecoveredFromCorruption);
        Assert.NotNull(recovered.CorruptBackupPath);
        Assert.True(File.Exists(recovered.CorruptBackupPath));
        Assert.Contains("not json", File.ReadAllText(recovered.CorruptBackupPath!));
        Assert.Empty(recovered.Manifest.Bills);
    }

    [Fact]
    public void SchemaVersionIsPersisted()
    {
        var session = BuildFinalizedSession();
        var json = File.ReadAllText(Path.Combine(session.RootDir, "manifest.json"));
        Assert.Contains("\"schema_version\": 1", json);
        Assert.Contains("\"finalized\": true", json);

        var reloaded = new SessionManager(_sessionsRoot, _sid);
        Assert.True(reloaded.Manifest.Finalized);
        Assert.Equal(SessionManifest.CurrentSchemaVersion, reloaded.Manifest.SchemaVersion);
        Assert.Single(reloaded.Manifest.Trips);
        Assert.Equal(3, reloaded.Manifest.Trips[0].Bills.Count);
    }

    [Fact]
    public void SecretProtectorRoundTrips()
    {
        // 非 Windows（测试机）为明文直通；Windows 上为 dpapi: 密文。两种情况往返都必须还原。
        var stored = SecretProtector.Protect("sk-test-123");
        Assert.Equal("sk-test-123", SecretProtector.Unprotect(stored));
        // 历史明文兼容
        Assert.Equal("plain-key", SecretProtector.Unprotect("plain-key"));
        // 坏密文返回空，不把密文当 Key
        if (OperatingSystem.IsWindows())
            Assert.Equal("", SecretProtector.Unprotect("dpapi:!!!not-base64!!!"));
    }

    [Fact]
    public void SettingsStorePreservesKeysAcrossSaveLoad()
    {
        var envPath = Path.Combine(_root, "settings.env");
        var store = new LlmSettingsStore(envPath);
        var keyValue = string.Concat("sk-", "live-", "abc");
        store.Settings.ApiKey = keyValue;
        store.Settings.OxrApiKey = "oxr-key-456";
        store.Save();

        var loaded = LlmSettingsStore.Load(envPath);
        Assert.Equal(keyValue, loaded.ApiKey);
        Assert.Equal("oxr-key-456", loaded.OxrApiKey);
    }
}
