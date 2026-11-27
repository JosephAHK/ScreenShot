using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace ScreenShot;

internal enum AnnotationTool { Pointer, Arrow, Rectangle, FocusDim }

internal enum AnnotationKind { Arrow, Rectangle, FocusDim }

internal sealed class Annotation
{
    public AnnotationKind Kind { get; }
    /// <summary>Overlay-local physical pixel coords.</summary>
    public PointF Start { get; set; }
    public PointF End { get; set; }

    public Annotation(AnnotationKind kind, PointF start, PointF end)
    {
        Kind = kind;
        Start = start;
        End = end;
    }

    public RectangleF Rect => RectangleF.FromLTRB(
        Math.Min(Start.X, End.X), Math.Min(Start.Y, End.Y),
        Math.Max(Start.X, End.X), Math.Max(Start.Y, End.Y));

    public Annotation Offset(float dx, float dy) =>
        new(Kind, new PointF(Start.X + dx, Start.Y + dy), new PointF(End.X + dx, End.Y + dy));

    public Annotation Clone() => new(Kind, Start, End);
}

/// <summary>Draws annotations identically in the live preview and in the saved image.</summary>
internal static class AnnotationRenderer
{
    public static readonly Color Red = Color.FromArgb(255, 59, 48);
    public const float FocusDimOpacity = 0.48f;
    public const float RectangleLineWidth = 6f;
    public const float ArrowShaftLineWidth = 7f;

    /// <summary>
    /// Focus dims first (each darkens everything in <paramref name="clip"/> outside its rect),
    /// then strokes on top — same order as the macOS compositor.
    /// </summary>
    public static void DrawAll(Graphics g, IEnumerable<Annotation> annotations, RectangleF clip, float scale, bool preview)
    {
        var list = annotations.ToList();
        var state = g.Save();
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.SetClip(clip);

        foreach (var a in list.Where(a => a.Kind == AnnotationKind.FocusDim))
        {
            using var region = new Region(clip);
            region.Exclude(Rectangle.Round(a.Rect));
            using var b = new SolidBrush(Color.FromArgb((int)(255 * FocusDimOpacity), 0, 0, 0));
            g.FillRegion(b, region);
            if (preview)
            {
                using var p = new Pen(Color.FromArgb(140, 255, 255, 255), 1f);
                var r = Rectangle.Round(a.Rect);
                g.DrawRectangle(p, r.X, r.Y, r.Width - 1, r.Height - 1);
            }
        }

        foreach (var a in list.Where(a => a.Kind != AnnotationKind.FocusDim))
            DrawStroke(g, a, scale);

        g.Restore(state);
    }

    public static void DrawStroke(Graphics g, Annotation a, float scale)
    {
        using var brush = new SolidBrush(Red);
        switch (a.Kind)
        {
            case AnnotationKind.Rectangle:
            {
                using var pen = new Pen(Red, RectangleLineWidth * scale) { LineJoin = LineJoin.Round };
                var r = a.Rect;
                if (r.Width > 0 && r.Height > 0) g.DrawRectangle(pen, r.X, r.Y, r.Width, r.Height);
                break;
            }
            case AnnotationKind.Arrow:
            {
                float dx = a.End.X - a.Start.X, dy = a.End.Y - a.Start.Y;
                float len = MathF.Sqrt(dx * dx + dy * dy);
                if (len <= 0.5f * scale) return;
                float headLen = Math.Min(22f * scale, Math.Max(10f * scale, len * 0.32f));
                float ux = dx / len, uy = dy / len;
                float baseX = a.End.X - ux * headLen, baseY = a.End.Y - uy * headLen;

                using (var pen = new Pen(Red, ArrowShaftLineWidth * scale) { StartCap = LineCap.Round, EndCap = LineCap.Flat })
                    g.DrawLine(pen, a.Start.X, a.Start.Y, baseX + ux * 0.5f, baseY + uy * 0.5f);

                float px = -uy, py = ux, halfW = headLen * 0.6f;
                g.FillPolygon(brush, new[]
                {
                    a.End,
                    new PointF(baseX + px * halfW, baseY + py * halfW),
                    new PointF(baseX - px * halfW, baseY - py * halfW)
                });
                break;
            }
        }
    }

    /// <summary>Crops <paramref name="source"/> to <paramref name="selection"/> and burns in annotations.</summary>
    public static Bitmap Composite(Bitmap source, Rectangle selection, IEnumerable<Annotation> annotations, float scale, bool sourceIsCropped)
    {
        var result = new Bitmap(selection.Width, selection.Height, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(result);
        g.CompositingMode = CompositingMode.SourceCopy;
        g.InterpolationMode = InterpolationMode.NearestNeighbor;
        g.PixelOffsetMode = PixelOffsetMode.Half;
        var src = sourceIsCropped ? new Rectangle(0, 0, selection.Width, selection.Height) : selection;
        g.DrawImage(source, new Rectangle(0, 0, selection.Width, selection.Height), src, GraphicsUnit.Pixel);
        g.CompositingMode = CompositingMode.SourceOver;

        var shifted = annotations.Select(a => a.Offset(-selection.X, -selection.Y)).ToList();
        if (shifted.Count > 0)
            DrawAll(g, shifted, new RectangleF(0, 0, selection.Width, selection.Height), scale, preview: false);
        return result;
    }
}
