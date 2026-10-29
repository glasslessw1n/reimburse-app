using OpenCvSharp;
using Reimbursement.Core.Recognition;
using Sdcb.PaddleInference;
using Sdcb.PaddleOCR;
using Sdcb.PaddleOCR.Models;
using Sdcb.PaddleOCR.Models.Local;

namespace Reimbursement.Ocr;

/// <summary>
/// 内置离线 OCR 引擎：Sdcb.PaddleOCR + PP-OCRv5 中文 mobile 模型（本地打包，随应用分发）。
/// PaddleOcrAll 非线程安全且初始化较重——懒加载单例 + 串行锁，识别管线顺序调用正好匹配。
/// </summary>
public sealed class PaddleOcrEngine : IImageOcrEngine, IDisposable
{
    private readonly Lazy<PaddleOcrAll> _engine;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public string DisplayName => "PaddleOCR（内置）";

    public PaddleOcrEngine()
    {
        _engine = new Lazy<PaddleOcrAll>(() =>
            new PaddleOcrAll(LocalFullModels.ChineseV5, PaddleDevice.Mkldnn())
            {
                AllowRotateDetection = true,
                Enable180Classification = false,
            });
    }

    public async Task<IReadOnlyList<OcrBlock>> RecognizeBlocksAsync(
        byte[] imageBytes, CancellationToken ct = default)
    {
        if (imageBytes.Length == 0) return Array.Empty<OcrBlock>();
        await _gate.WaitAsync(ct);
        try
        {
            // Paddle 推理是同步 CPU 工作，放后台线程避免卡 UI。
            return await Task.Run<IReadOnlyList<OcrBlock>>(() =>
            {
                ct.ThrowIfCancellationRequested();
                using var src = Cv2.ImDecode(imageBytes, ImreadModes.Color);
                if (src.Empty()) return Array.Empty<OcrBlock>();
                var result = _engine.Value.Run(src);
                return result.Regions
                    .Select(r => new OcrBlock(
                        r.Text,
                        r.Rect.Center.X,
                        r.Rect.Center.Y,
                        r.Rect.Size.Width,
                        r.Rect.Size.Height,
                        r.Score))
                    .ToList();
            }, ct);
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Dispose()
    {
        if (_engine.IsValueCreated) _engine.Value.Dispose();
        _gate.Dispose();
    }
}
