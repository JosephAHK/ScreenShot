using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace ScreenShot;

/// <summary>Vector icons drawn with GDI+ so they stay crisp at any DPI.</summary>
internal static class Icons
{
    public enum Glyph
    {
        Pointer, Arrow, Rectangle, Focus, Undo, Copy, Timer, CopyText,
        Camera, Folder, Trash, Check, Photo
    }

    /// <summary>Draws a glyph centred in <paramref name="box"/>.</summary>
    public static void Draw(Graphics g, Glyph glyph, RectangleF box, Color color, float size)
    {
        var state = g.Save();
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        float s = size / 16f; // glyphs are designed on a 16x16 grid
        float ox = box.X + (box.Width - size) / 2f;
        float oy = box.Y + (box.Height - size) / 2f;
        g.TranslateTransform(ox, oy);
        g.ScaleTransform(s, s);

        using var pen = new Pen(color, 1.6f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        using var brush = new SolidBrush(color);

        switch (glyph)
        {
            case Glyph.Pointer:
            {
                var pts = new PointF[]
                {
                    new(4, 1.5f), new(4, 13.5f), new(7, 10.6f), new(9.2f, 15f),
                    new(11, 14.1f), new(8.9f, 9.8f), new(13, 9.6f)
                };
                g.FillPolygon(brush, pts);
                break;
            }
            case Glyph.Arrow:
                using (var p = new Pen(color, 2f) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                    g.DrawLine(p, 3, 13, 11.5f, 4.5f);
                g.FillPolygon(brush, new PointF[] { new(14, 2), new(13.4f, 8.6f), new(7.4f, 2.6f) });
                break;
            case Glyph.Rectangle:
                g.DrawRectangle(pen, 2, 3.5f, 12, 9);
                break;
            case Glyph.Focus:
                DrawBrackets(g, pen, 1.5f, 1.5f, 13, 13, 4);
                g.FillEllipse(brush, 6, 6, 4, 4);
                break;
            case Glyph.Undo:
            {
                using var path = new GraphicsPath();
                path.AddArc(4, 4, 10, 9, 270, 200);
                g.DrawPath(pen, path);
                g.DrawLine(pen, 9, 4, 4, 4);
                g.FillPolygon(brush, new PointF[] { new(1.5f, 4), new(5.5f, 0.8f), new(5.5f, 7.2f) });
                break;
            }
            case Glyph.Copy:
                using (var back = RoundRect(new RectangleF(5.5f, 1.5f, 9, 10.5f), 1.6f))
                    g.DrawPath(pen, back);
                using (var front = RoundRect(new RectangleF(1.5f, 4.5f, 9, 10.5f), 1.6f))
                {
                    g.FillPath(brush, front);
                }
                break;
            case Glyph.Timer:
                g.DrawEllipse(pen, 2.5f, 3.5f, 11, 11);
                g.DrawLine(pen, 8, 9, 8, 5.8f);
                g.DrawLine(pen, 8, 9, 10.2f, 10.6f);
                g.DrawLine(pen, 6.2f, 1.2f, 9.8f, 1.2f);
                break;
            case Glyph.CopyText:
                DrawBrackets(g, pen, 1.5f, 1.5f, 13, 13, 3.5f);
                using (var tp = new Pen(color, 1.8f) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                {
                    g.DrawLine(tp, 5, 5.5f, 11, 5.5f);
                    g.DrawLine(tp, 8, 5.5f, 8, 11.5f);
                }
                break;
            case Glyph.Camera:
                DrawBrackets(g, pen, 1, 1.5f, 14, 13, 3.5f);
                using (var body = RoundRect(new RectangleF(4, 5.5f, 8, 6), 1.2f))
                    g.DrawPath(pen, body);
                g.DrawEllipse(pen, 6.6f, 7.1f, 2.8f, 2.8f);
                break;
            case Glyph.Folder:
            {
                using var path = new GraphicsPath();
                path.AddLines(new PointF[]
                {
                    new(1.5f, 13.5f), new(1.5f, 2.8f), new(6, 2.8f), new(7.6f, 4.6f),
                    new(14.5f, 4.6f), new(14.5f, 13.5f)
                });
                path.CloseFigure();
                g.DrawPath(pen, path);
                g.DrawLine(pen, 1.5f, 6.8f, 14.5f, 6.8f);
                break;
            }
            case Glyph.Trash:
            {
                g.FillRectangle(brush, 2, 3, 12, 1.6f);
                g.FillRectangle(brush, 6, 1, 4, 2.2f);
                using var path = new GraphicsPath();
                path.AddLines(new PointF[] { new(3.4f, 5.4f), new(12.6f, 5.4f), new(11.7f, 15), new(4.3f, 15) });
                path.CloseFigure();
                g.FillPath(brush, path);
                break;
            }
            case Glyph.Check:
                using (var cp = new Pen(color, 2.2f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
                    g.DrawLines(cp, new PointF[] { new(3.5f, 8.5f), new(6.6f, 11.6f), new(12.6f, 4.6f) });
                break;
            case Glyph.Photo:
                using (var fr = RoundRect(new RectangleF(1.5f, 2.5f, 13, 11), 1.5f))
                    g.DrawPath(pen, fr);
                g.FillPolygon(brush, new PointF[] { new(3, 12), new(6.5f, 7.5f), new(9, 10), new(10.5f, 8.5f), new(13, 12) });
                g.FillEllipse(brush, 9.8f, 4.4f, 2.4f, 2.4f);
                break;
        }

        g.Restore(state);
    }

    private static void DrawBrackets(Graphics g, Pen pen, float x, float y, float w, float h, float len)
    {
        float r = x + w, b = y + h;
        g.DrawLines(pen, new PointF[] { new(x, y + len), new(x, y), new(x + len, y) });
        g.DrawLines(pen, new PointF[] { new(r - len, y), new(r, y), new(r, y + len) });
        g.DrawLines(pen, new PointF[] { new(r, b - len), new(r, b), new(r - len, b) });
        g.DrawLines(pen, new PointF[] { new(x + len, b), new(x, b), new(x, b - len) });
    }

    public static GraphicsPath RoundRect(RectangleF r, float radius)
    {
        var path = new GraphicsPath();
        float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        if (d <= 0.01f)
        {
            path.AddRectangle(r);
            return path;
        }
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    // ---------------------------------------------------------------- app icon

    /// <summary>Camera viewfinder on an orange→red gradient squircle (matches the macOS icon).</summary>
    public static Bitmap RenderAppIcon(int px)
    {
        var bmp = new Bitmap(px, px, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.Clear(Color.Transparent);

        float inset = px >= 48 ? px * 0.06f : 0;
        var rect = new RectangleF(inset, inset, px - inset * 2, px - inset * 2);
        using (var path = RoundRect(rect, rect.Width * 0.225f))
        using (var grad = new LinearGradientBrush(rect, Color.FromArgb(255, 159, 10), Color.FromArgb(255, 59, 48), 60f))
            g.FillPath(grad, path);

        float u = rect.Width / 16f;
        float stroke = Math.Max(1.2f, u * 1.35f);
        using var pen = new Pen(Color.White, stroke) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        float x = rect.X + u * 3f, y = rect.Y + u * 3f, w = u * 10f, h = u * 10f, len = u * 3f;
        DrawBrackets(g, pen, x, y, w, h, len);
        float c = rect.X + rect.Width / 2f, cy = rect.Y + rect.Height / 2f;
        float lr = u * 2.1f;
        g.DrawEllipse(pen, c - lr, cy - lr, lr * 2, lr * 2);
        return bmp;
    }

    /// <summary>Writes a multi-resolution .ico (PNG-compressed entries).</summary>
    public static void WriteIco(string path)
    {
        int[] sizes = { 16, 20, 24, 32, 40, 48, 64, 128, 256 };
        var pngs = sizes.Select(sz =>
        {
            using var bmp = RenderAppIcon(sz);
            using var ms = new MemoryStream();
            bmp.Save(ms, ImageFormat.Png);
            return ms.ToArray();
        }).ToArray();

        using var fs = File.Create(path);
        using var w = new BinaryWriter(fs);
        w.Write((short)0);
        w.Write((short)1);
        w.Write((short)sizes.Length);
        int offset = 6 + 16 * sizes.Length;
        for (int i = 0; i < sizes.Length; i++)
        {
            w.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i]));
            w.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i]));
            w.Write((byte)0);
            w.Write((byte)0);
            w.Write((short)1);
            w.Write((short)32);
            w.Write(pngs[i].Length);
            w.Write(offset);
            offset += pngs[i].Length;
        }
        foreach (var png in pngs) w.Write(png);
    }

    private static Icon? _appIcon;

    public static Icon AppIcon
    {
        get
        {
            if (_appIcon != null) return _appIcon;
            using var s = typeof(Icons).Assembly.GetManifestResourceStream("AppIcon.ico");
            _appIcon = s != null ? new Icon(s) : Icon.FromHandle(RenderAppIcon(32).GetHicon());
            return _appIcon;
        }
    }

    public static Icon TrayIcon(int px)
    {
        using var s = typeof(Icons).Assembly.GetManifestResourceStream("AppIcon.ico");
        if (s != null) return new Icon(s, new Size(px, px));
        return Icon.FromHandle(RenderAppIcon(px).GetHicon());
    }
}
