using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace ScreenShot;

/// <summary>On-device OCR via Windows.Media.Ocr (uses the user's installed OCR languages).</summary>
internal static class OcrService
{
    public static async Task<string> RecognizeTextAsync(Bitmap source)
    {
        var engine = OcrEngine.TryCreateFromUserProfileLanguages()
                     ?? OcrEngine.TryCreateFromLanguage(new Windows.Globalization.Language("en-US"))
                     ?? throw new InvalidOperationException(
                         "No Windows OCR language is installed. Add one under Settings → Time & Language → Language.");

        // Windows OCR reads small UI text much better when upscaled.
        int max = (int)OcrEngine.MaxImageDimension;
        float scale = 1f;
        int longest = Math.Max(source.Width, source.Height);
        if (longest * 2 <= max && source.Height < 1200) scale = 2f;
        else if (longest > max) scale = (float)max / longest;

        using var scaled = Scale(source, scale);
        using var soft = ToSoftwareBitmap(scaled);
        var result = await engine.RecognizeAsync(soft);

        var lines = result.Lines
            .Select(l => l.Text.Trim())
            .Where(t => t.Length > 0)
            .ToList();
        return string.Join(Environment.NewLine, lines);
    }

    private static Bitmap Scale(Bitmap src, float scale)
    {
        if (Math.Abs(scale - 1f) < 0.001f) return new Bitmap(src);
        int w = Math.Max(1, (int)Math.Round(src.Width * scale));
        int h = Math.Max(1, (int)Math.Round(src.Height * scale));
        var dst = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(dst);
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.DrawImage(src, new Rectangle(0, 0, w, h));
        return dst;
    }

    private static SoftwareBitmap ToSoftwareBitmap(Bitmap bmp)
    {
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var bytes = new byte[data.Stride * data.Height];
            System.Runtime.InteropServices.Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            // Pack rows tightly if stride has padding (32bpp never does, but be safe).
            int tight = bmp.Width * 4;
            if (data.Stride != tight)
            {
                var packed = new byte[tight * bmp.Height];
                for (int y = 0; y < bmp.Height; y++)
                    Buffer.BlockCopy(bytes, y * data.Stride, packed, y * tight, tight);
                bytes = packed;
            }
            return SoftwareBitmap.CreateCopyFromBuffer(bytes.AsBuffer(), BitmapPixelFormat.Bgra8,
                bmp.Width, bmp.Height, BitmapAlphaMode.Premultiplied);
        }
        finally
        {
            bmp.UnlockBits(data);
        }
    }
}
