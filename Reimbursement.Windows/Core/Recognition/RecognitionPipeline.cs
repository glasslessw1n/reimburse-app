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
/// 识别管线：逐张 文档文本提取 → LLM 两段式识别 → 登记回调，
/// 全程通过 IProgress 汇报进度，最终返回汇总。顺序执行——本地 OCR 引擎
/// （PaddleOCR）非线程安全，且 LLM 顺序调用便于限流与取消。
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
        CancellationToken ct = default)
    {
        var items = new List<RecognitionItemResult>();
        var completed = 0;

        foreach (var name in fileNames)
        {
            ct.ThrowIfCancellationRequested();
            progress?.Report(new RecognitionProgress(
                fileNames.Count, completed, name, RecognitionStage.ExtractingText, "正在提取文本…"));

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
                ingest(failed);
                completed++;
                items.Add(new RecognitionItemResult(name, false, true, message, doc.Source.ToString()));
                progress?.Report(new RecognitionProgress(
                    fileNames.Count, completed, name, RecognitionStage.Failed, message));
                continue;
            }

            progress?.Report(new RecognitionProgress(
                fileNames.Count, completed, name, RecognitionStage.Recognizing,
                doc.Source == DocumentTextSource.PdfTextLayer ? "文本层直提，正在调用模型识别…" : "OCR 完成，正在调用模型识别…"));

            var receipt = await _recognizer.RecognizeAsync(doc.Text, name, name, ct);
            var bill = BillFactory.FromReceipt(receipt, name);
            ingest(bill);
            completed++;

            var ok = bill.Error.Length == 0;
            var itemMessage = ok
                ? $"{bill.BillType.DisplayName()} ¥{bill.Amount:0.00}" + (bill.NeedsReview ? "（需复核）" : "")
                : $"识别失败——{bill.Error}";
            items.Add(new RecognitionItemResult(name, ok, bill.NeedsReview, itemMessage, doc.Source.ToString()));
            progress?.Report(new RecognitionProgress(
                fileNames.Count, completed, name,
                ok ? RecognitionStage.Completed : RecognitionStage.Failed, itemMessage));
        }

        return new RecognitionSummary(
            fileNames.Count,
            items.Count(i => i.Success),
            items.Count(i => !i.Success),
            items.Count(i => i.NeedsReview),
            items);
    }
}
