using System.Globalization;
using Reimbursement.Core.Llm;
using Reimbursement.Core.Models;

namespace Reimbursement.Core.Recognition;

/// <summary>单张票据在识别管线中的阶段（UI 进度与行状态共用）。</summary>
public enum RecognitionStage
{
    ExtractingText,
    Recognizing,
    Completed,
    Failed,
}

/// <summary>识别进度事件：总数、已完成数、当前文件与阶段。</summary>
public sealed record RecognitionProgress(
    int Total,
    int Completed,
    string FileName,
    RecognitionStage Stage,
    string Message = "");

/// <summary>单张票据的识别结果。</summary>
public sealed record RecognitionItemResult(
    string FileName,
    bool Success,
    bool NeedsReview,
    string Message,
    string TextSource = "");

/// <summary>一批识别的完成汇总（UI 完成横幅直接用）。</summary>
public sealed record RecognitionSummary(
    int Total,
    int Succeeded,
    int Failed,
    int NeedsReview,
    IReadOnlyList<RecognitionItemResult> Items);

/// <summary>Receipt → BillInfo 的组装（金额取 fields["amount"]，低置信标复核）。</summary>
public static class BillFactory
{
    public static BillInfo FromReceipt(Receipt receipt, string sourceFile)
    {
        double amount = 0;
        if (receipt.Fields.TryGetValue("amount", out var raw) && raw != null)
            double.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out amount);
        var lowConfidence = receipt.Error.Length == 0 && receipt.Confidence < 0.7;
        return new BillInfo(receipt.ReceiptType, amount, sourceFile, receipt.Fields)
        {
            Confidence = receipt.Confidence,
            Error = receipt.Error,
            NeedsReview = lowConfidence,
            ReviewReason = lowConfidence ? $"识别置信度偏低（{receipt.Confidence:0.00}）" : "",
            RawTextSnippet = receipt.RawTextExcerpt,
        };
    }
}

/// <summary>
/// 识别管线（评估 H3 分段并行）：两段推进——
/// 第一段文本提取严格串行（本地 PaddleOCR 非线程安全，且渲染/OCR 都是 CPU 活）；
/// 第二段 LLM 识别是网络等待，有界并发（默认 3）重叠往返，汇总顺序仍按输入序。
/// ingest 回调（会话落盘）非线程安全，并发段内串行化调用。
/// 文本提取失败也会登记一张带 error 的 BillInfo，让 UI 能展示失败行并提供单张重试。
/// </summary>
public sealed class RecognitionPipeline
{
    private readonly IDocumentTextProvider _textProvider;
    private readonly LlmRecognizer _recognizer;

    public RecognitionPipeline(IDocumentTextProvider textProvider, LlmRecognizer recognizer)
    {
        _textProvider = textProvider;
        _recognizer = recognizer;
    }

    public async Task<RecognitionSummary> RunAsync(
        IReadOnlyList<string> fileNames,
        Func<string, string> pathOf,
        Action<BillInfo> ingest,
        IProgress<RecognitionProgress>? progress = null,
        CancellationToken ct = default,
        int llmConcurrency = 3)
    {
        var total = fileNames.Count;
        var slots = new RecognitionItemResult?[total];
        var completed = 0;
        var ingestGate = new object();
        int CompleteOne(int idx, RecognitionItemResult item)
        {
            slots[idx] = item;
            return Interlocked.Increment(ref completed);
        }

        // 第一段：串行提取文本（OCR/渲染不并发）
        var extracted = new List<(int Idx, string Name, DocumentTextResult Doc)>();
        for (var i = 0; i < total; i++)
        {
            var name = fileNames[i];
            ct.ThrowIfCancellationRequested();
            progress?.Report(new RecognitionProgress(
                total, completed, name, RecognitionStage.ExtractingText, "正在提取文本…"));

            var doc = await _textProvider.ExtractAsync(pathOf(name), ct);
            if (!doc.HasUsableText)
            {
                var message = doc.Message.Length > 0 ? doc.Message : "未提取到可用文本";
                var failed = new BillInfo(BillType.Other, 0, name)
                {
                    Confidence = 0,
                    Error = message,
                    NeedsReview = true,
                    ReviewReason = "文本提取失败，可重试或检查 OCR 设置",
                };
                lock (ingestGate) ingest(failed);
                CompleteOne(i, new RecognitionItemResult(name, false, true, message, doc.Source.ToString()));
                progress?.Report(new RecognitionProgress(
                    total, completed, name, RecognitionStage.Failed, message));
                continue;
            }
            extracted.Add((i, name, doc));
        }

        // 第二段：LLM 有界并发（ingest 与进度计数串行化）
        using var sem = new SemaphoreSlim(Math.Max(1, llmConcurrency));
        var tasks = extracted.Select(async entry =>
        {
            await sem.WaitAsync(ct);
            try
            {
                var (idx, name, doc) = entry;
                progress?.Report(new RecognitionProgress(
                    total, completed, name, RecognitionStage.Recognizing,
                    doc.Source == DocumentTextSource.PdfTextLayer ? "文本层直提，正在调用模型识别…" : "OCR 完成，正在调用模型识别…"));

                var receipt = await _recognizer.RecognizeAsync(doc.Text, name, name, ct);
                var bill = BillFactory.FromReceipt(receipt, name);
                lock (ingestGate) ingest(bill);

                var ok = bill.Error.Length == 0;
                var itemMessage = ok
                    ? $"{bill.BillType.DisplayName()} ¥{bill.Amount:0.00}" + (bill.NeedsReview ? "（需复核）" : "")
                    : $"识别失败——{bill.Error}";
                var done = CompleteOne(idx, new RecognitionItemResult(name, ok, bill.NeedsReview, itemMessage, doc.Source.ToString()));
                progress?.Report(new RecognitionProgress(
                    total, done, name,
                    ok ? RecognitionStage.Completed : RecognitionStage.Failed, itemMessage));
            }
            finally { sem.Release(); }
        });
        await Task.WhenAll(tasks);

        var items = slots.Select(s => s!).ToList();
        return new RecognitionSummary(
            total,
            items.Count(i => i.Success),
            items.Count(i => !i.Success),
            items.Count(i => i.NeedsReview),
            items);
    }
}
