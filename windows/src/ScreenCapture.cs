using System.Drawing.Imaging;

namespace ScreenShot;

internal static class ScreenCapture
{
    /// <summary>
    /// Copies a rectangle of the desktop (virtual-screen physical pixels) 1:1.
    /// The process is Per-Monitor-V2 DPI aware, so no scaling happens.
    /// </summary>
    public static Bitmap CaptureRect(Rectangle rect)
    {
        if (rect.Width < 1 || rect.Height < 1) throw new ArgumentException("Selected region is empty.");
        var bmp = new Bitmap(rect.Width, rect.Height, PixelFormat.Format32bppArgb);
        IntPtr screenDc = Native.GetDC(IntPtr.Zero);
        try
        {
            using var g = Graphics.FromImage(bmp);
            IntPtr dst = g.GetHdc();
            try
            {
                Native.BitBlt(dst, 0, 0, rect.Width, rect.Height, screenDc, rect.X, rect.Y,
                    Native.SRCCOPY);
            }
            finally
            {
                g.ReleaseHdc(dst);
            }
        }
        finally
        {
            Native.ReleaseDC(IntPtr.Zero, screenDc);
        }
        // BitBlt leaves alpha at 0 on some drivers; force opaque.
        ForceOpaque(bmp);
        return bmp;
    }

    private static unsafe void ForceOpaque(Bitmap bmp)
    {
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        try
        {
            for (int y = 0; y < data.Height; y++)
            {
                uint* row = (uint*)((byte*)data.Scan0 + (long)y * data.Stride);
                for (int x = 0; x < data.Width; x++) row[x] |= 0xFF000000;
            }
        }
        finally
        {
            bmp.UnlockBits(data);
        }
    }
}
