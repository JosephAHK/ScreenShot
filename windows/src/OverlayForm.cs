using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;

namespace ScreenShot;

/// <summary>
/// Full-screen, borderless, top-most window for one monitor. Shows a frozen frame of that
/// monitor dimmed to 55 %, with the drag selection kept bright, plus the annotation toolbar.
/// All coordinates are monitor-local physical pixels.
/// </summary>
internal sealed class OverlayForm : Form
{
    private enum Phase { AwaitingSelection, Selecting, Idle, Annotating, EditingAnnotation }

    private enum ControlPoint { None, Corner0, Corner1, Corner2, Corner3, ArrowStart, ArrowEnd, Move }

    private enum ToolbarButton
    {
        None = -1, Pointer, Arrow, Rectangle, Focus, Undo, Copy, Timer, CopyText
    }

    private static readonly (ToolbarButton Button, Icons.Glyph Glyph, string Tip)[] ToolbarItems =
    {
        (ToolbarButton.Pointer, Icons.Glyph.Pointer, "Select (V)"),
        (ToolbarButton.Arrow, Icons.Glyph.Arrow, "Arrow (A)"),
        (ToolbarButton.Rectangle, Icons.Glyph.Rectangle, "Rectangle (R)"),
        (ToolbarButton.Focus, Icons.Glyph.Focus, "Focus dim (F)"),
        (ToolbarButton.Undo, Icons.Glyph.Undo, "Undo (Ctrl+Z)"),
        (ToolbarButton.Copy, Icons.Glyph.Copy, "Copy (Ctrl+C / Enter)"),
        (ToolbarButton.Timer, Icons.Glyph.Timer, "Timed capture (5s)"),
        (ToolbarButton.CopyText, Icons.Glyph.CopyText, "Copy text (OCR)"),
    };

    private static readonly Color Accent = Color.FromArgb(0, 120, 212);

    private readonly OverlayController _controller;
    private readonly Bitmap _frozen;
    private readonly Bitmap _dimmed;
    public Rectangle ScreenBounds { get; }
    public float Scale { get; }

    private Phase _phase = Phase.AwaitingSelection;
    private Point? _selDragStart, _selDragCurrent;
    private Rectangle? _selection;

    private readonly List<Annotation> _annotations = new();
    private PointF? _annDragStart, _annDragCurrent;
    private int? _selectedAnnotation;
    private ControlPoint _activeControlPoint = ControlPoint.None;
    private PointF? _moveLast;

    private Rectangle? _pendingRestoreSelection;
    private List<Annotation> _pendingRestoreAnnotations = new();

    private AnnotationTool? _tool;
    private Rectangle _toolbarRect;
    private bool _toolbarVisible;
    private readonly Dictionary<ToolbarButton, Rectangle> _buttonRects = new();
    private ToolbarButton _hoverButton = ToolbarButton.None;
    private ToolbarButton _pressedButton = ToolbarButton.None;
    private bool _undoFlash;

    private float MinSelectionSide => 20 * Scale;
    private float HitRadius => 9 * Scale;
    private float HandleRadius => 5 * Scale;

    public OverlayForm(OverlayController controller, Rectangle screenBounds, Bitmap frozen)
    {
        _controller = controller;
        ScreenBounds = screenBounds;
        Scale = Native.ScaleForScreen(screenBounds);
        _frozen = ToPArgb(frozen);
        _dimmed = MakeDimmed(_frozen, 0.55f);

        AutoScaleMode = AutoScaleMode.None;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        KeyPreview = true;
        DoubleBuffered = true;
        BackColor = Color.Black;
        Bounds = screenBounds;
        Cursor = Cursors.Cross;
        Text = "ScreenShot overlay";
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.Opaque, true);
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST;
            return cp;
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        int one = 1;
        Native.DwmSetWindowAttribute(Handle, Native.DWMWA_TRANSITIONS_FORCEDISABLED, ref one, sizeof(int));
        // Start cloaked: DWM would otherwise show a blank (white) surface until the first
        // full-screen paint finishes. Reveal() uncloaks once the frame is drawn.
        Native.SetCloaked(Handle, true);
        PlaceOnScreen();
    }

    public void PlaceOnScreen()
    {
        Native.SetWindowPos(Handle, Native.HWND_TOPMOST, ScreenBounds.X, ScreenBounds.Y,
            ScreenBounds.Width, ScreenBounds.Height, Native.SWP_SHOWWINDOW);
    }

    protected override void WndProc(ref Message m)
    {
        // Keep exact physical bounds when created on a monitor with a different DPI.
        if (m.Msg == Native.WM_DPICHANGED)
        {
            PlaceOnScreen();
            return;
        }
        if (m.Msg == 0x0014) // WM_ERASEBKGND: never paint the black background; OnPaint covers everything
        {
            m.Result = (IntPtr)1;
            return;
        }
        base.WndProc(ref m);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _frozen.Dispose();
            _dimmed.Dispose();
        }
        base.Dispose(disposing);
    }

    /// <summary>Hide from the compositor before (re)showing, to avoid a white flash.</summary>
    public void Cloak()
    {
        if (IsHandleCreated) Native.SetCloaked(Handle, true);
    }

    /// <summary>Paint synchronously, let DWM pick up the frame, then make it visible.</summary>
    public void Reveal()
    {
        Invalidate();
        Update();
        Native.DwmFlush();
        Native.SetCloaked(Handle, false);
    }

    public void ActivateOverlay()
    {
        Activate();
        Native.SetForegroundWindow(Handle);
        Focus();
    }

    // ------------------------------------------------------------------ state from controller

    public bool HasSelection => _selection.HasValue;

    /// <summary>Another monitor started a selection: drop ours.</summary>
    public void ResetSelection()
    {
        if (_selection == null && _phase == Phase.AwaitingSelection) return;
        _selection = null;
        _annotations.Clear();
        _selectedAnnotation = null;
        _selDragStart = _selDragCurrent = null;
        _annDragStart = _annDragCurrent = null;
        _phase = Phase.AwaitingSelection;
        _toolbarVisible = false;
        _tool = null;
        Invalidate();
    }

    public Bitmap CropFrozen(Rectangle localRect) =>
        _frozen.Clone(localRect, PixelFormat.Format32bppArgb);

    public Bitmap CompositeFromFrozen() =>
        AnnotationRenderer.Composite(_frozen, _selection!.Value, _annotations, Scale, sourceIsCropped: false);

    public Rectangle? Selection => _selection;
    public IReadOnlyList<Annotation> Annotations => _annotations;

    public void RestoreToolbarAfterCountdown()
    {
        if (_selection is { } sel) PositionToolbar(sel);
        Invalidate();
    }

    // ------------------------------------------------------------------ painting

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.CompositingMode = CompositingMode.SourceCopy;
        g.InterpolationMode = InterpolationMode.NearestNeighbor;
        g.PixelOffsetMode = PixelOffsetMode.Half;
        var clip = e.ClipRectangle;
        g.DrawImage(_dimmed, clip, clip, GraphicsUnit.Pixel);

        var sel = CurrentSelection;
        if (sel is { Width: > 0, Height: > 0 } s)
        {
            var bright = Rectangle.Intersect(s, clip);
            if (!bright.IsEmpty) g.DrawImage(_frozen, bright, bright, GraphicsUnit.Pixel);
            g.CompositingMode = CompositingMode.SourceOver;

            var anns = new List<Annotation>(_annotations);
            if (_annDragStart is { } a0 && _annDragCurrent is { } a1 && _tool is { } t && t != AnnotationTool.Pointer)
                anns.Add(new Annotation(KindFor(t), a0, a1));
            if (anns.Count > 0) AnnotationRenderer.DrawAll(g, anns, s, Scale, preview: true);

            using (var border = new Pen(Color.FromArgb(230, 255, 255, 255), 1))
                g.DrawRectangle(border, s.X, s.Y, s.Width - 1, s.Height - 1);

            DrawBadge(g, $"{s.Width} × {s.Height}", s);

            if (_selectedAnnotation is int idx && idx < _annotations.Count)
                DrawHandles(g, _annotations[idx]);

            if (_toolbarVisible) DrawToolbar(g);
        }
        else
        {
            g.CompositingMode = CompositingMode.SourceOver;
            DrawCenteredHint(g, "Drag to select  ·  Ctrl+C / Enter to copy  ·  Esc to cancel");
        }
    }

    private Rectangle? CurrentSelection
    {
        get
        {
            if (_selection is { } s) return s;
            if (_selDragStart is { } a && _selDragCurrent is { } b) return RectFrom(a, b);
            return null;
        }
    }

    private Font UiFont(float pt, FontStyle style = FontStyle.Regular) =>
        new("Segoe UI", pt * Scale, style, GraphicsUnit.Pixel);

    private void DrawBadge(Graphics g, string text, Rectangle sel)
    {
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        using var font = UiFont(12, FontStyle.Bold);
        var size = g.MeasureString(text, font);
        float pad = 6 * Scale;
        float w = size.Width + pad * 2, h = size.Height + pad;
        float x = sel.X, y = sel.Y - h - 4 * Scale;
        if (y < 4 * Scale) y = sel.Bottom + 4 * Scale;
        if (x + w > ClientSize.Width - 4 * Scale) x = ClientSize.Width - 4 * Scale - w;
        if (x < 4 * Scale) x = 4 * Scale;
        var box = new RectangleF(x, y, w, h);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = Icons.RoundRect(box, 4 * Scale))
        using (var b = new SolidBrush(Color.FromArgb(166, 0, 0, 0)))
            g.FillPath(b, path);
        g.DrawString(text, font, Brushes.White, x + pad, y + pad / 2);
    }

    private void DrawCenteredHint(Graphics g, string text)
    {
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        using var font = UiFont(15, FontStyle.Bold);
        var size = g.MeasureString(text, font);
        float pad = 12 * Scale;
        float w = size.Width + pad * 2, h = size.Height + pad;
        var box = new RectangleF((ClientSize.Width - w) / 2, (ClientSize.Height - h) / 2, w, h);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = Icons.RoundRect(box, 7 * Scale))
        using (var b = new SolidBrush(Color.FromArgb(150, 0, 0, 0)))
            g.FillPath(b, path);
        using var tb = new SolidBrush(Color.FromArgb(235, 255, 255, 255));
        g.DrawString(text, font, tb, box.X + pad, box.Y + pad / 2);
    }

    private void DrawHandles(Graphics g, Annotation a)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float r = HandleRadius;
        using var outline = new Pen(Accent, 1.5f * Scale);
        foreach (var (_, pt) in ControlPoints(a))
        {
            var box = new RectangleF(pt.X - r, pt.Y - r, r * 2, r * 2);
            g.FillEllipse(Brushes.White, box);
            g.DrawEllipse(outline, box);
        }
    }

    private void DrawToolbar(Graphics g)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float radius = 10 * Scale;
        foreach (var group in ToolbarGroups())
        {
            using var path = Icons.RoundRect(group, radius);
            using var bg = new SolidBrush(Color.FromArgb(235, 36, 36, 38));
            using var border = new Pen(Color.FromArgb(40, 255, 255, 255), 1);
            g.FillPath(bg, path);
            g.DrawPath(border, path);
        }

        foreach (var (button, glyph, _) in ToolbarItems)
        {
            var r = _buttonRects[button];
            bool on = IsButtonOn(button) || (button == ToolbarButton.Undo && _undoFlash);
            bool hover = _hoverButton == button;
            if (on || hover)
            {
                using var path = Icons.RoundRect(r, 6 * Scale);
                using var b = new SolidBrush(on ? Accent : Color.FromArgb(31, 255, 255, 255));
                g.FillPath(b, path);
            }
            Icons.Draw(g, glyph, r, Color.White, 15 * Scale);
        }

        if (_hoverButton != ToolbarButton.None && _pressedButton == ToolbarButton.None)
        {
            var r = _buttonRects[_hoverButton];
            var tip = ToolbarItems.First(i => i.Button == _hoverButton).Tip;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            using var font = UiFont(12, FontStyle.Bold);
            var size = g.MeasureString(tip, font);
            float padX = 8 * Scale, padY = 4 * Scale;
            float w = size.Width + padX * 2, h = size.Height + padY * 2;
            float x = r.X + r.Width / 2f - w / 2f;
            float y = _toolbarRect.Y - h - 6 * Scale;
            if (y < 2) y = _toolbarRect.Bottom + 6 * Scale;
            x = Math.Clamp(x, 2, ClientSize.Width - w - 2);
            var box = new RectangleF(x, y, w, h);
            using var path = Icons.RoundRect(box, 6 * Scale);
            using var bg = new SolidBrush(Color.FromArgb(209, 0, 0, 0));
            using var border = new Pen(Color.FromArgb(31, 255, 255, 255), 1);
            g.FillPath(bg, path);
            g.DrawPath(border, path);
            g.DrawString(tip, font, Brushes.White, x + padX, y + padY);
        }
    }

    private bool IsButtonOn(ToolbarButton b) => b switch
    {
        ToolbarButton.Pointer => _tool == AnnotationTool.Pointer,
        ToolbarButton.Arrow => _tool == AnnotationTool.Arrow,
        ToolbarButton.Rectangle => _tool == AnnotationTool.Rectangle,
        ToolbarButton.Focus => _tool == AnnotationTool.FocusDim,
        _ => false
    };

    // ------------------------------------------------------------------ toolbar layout

    private IEnumerable<Rectangle> ToolbarGroups()
    {
        yield return GroupRect(ToolbarButton.Pointer, ToolbarButton.Undo);
        yield return GroupRect(ToolbarButton.Copy, ToolbarButton.CopyText);
    }

    private Rectangle GroupRect(ToolbarButton first, ToolbarButton last)
    {
        int padX = (int)(8 * Scale), padY = (int)(6 * Scale);
        var a = _buttonRects[first];
        var b = _buttonRects[last];
        return Rectangle.FromLTRB(a.X - padX, a.Y - padY, b.Right + padX, b.Bottom + padY);
    }

    private void PositionToolbar(Rectangle sel)
    {
        _tool = AnnotationTool.Pointer;
        _selectedAnnotation = null;

        int bw = (int)(30 * Scale), bh = (int)(26 * Scale);
        int gap = (int)(4 * Scale), padX = (int)(8 * Scale), padY = (int)(6 * Scale), groupGap = (int)(8 * Scale);
        int g1 = padX * 2 + bw * 5 + gap * 4;
        int g2 = padX * 2 + bw * 3 + gap * 2;
        int totalW = g1 + groupGap + g2;
        int totalH = bh + padY * 2;
        int margin = (int)(8 * Scale), edge = (int)(4 * Scale);

        int x = sel.X + sel.Width / 2 - totalW / 2;
        int y = sel.Bottom + margin;
        if (y + totalH > ClientSize.Height - edge)
        {
            y = sel.Y - totalH - margin;
            if (y < edge) y = Math.Max(edge, sel.Bottom - totalH - margin);
        }
        x = Math.Clamp(x, edge, Math.Max(edge, ClientSize.Width - totalW - edge));
        _toolbarRect = new Rectangle(x, y, totalW, totalH);

        _buttonRects.Clear();
        int bx = x + padX;
        for (int i = 0; i < ToolbarItems.Length; i++)
        {
            if (i == 5) bx += padX + groupGap + padX - gap;
            _buttonRects[ToolbarItems[i].Button] = new Rectangle(bx, y + padY, bw, bh);
            bx += bw + gap;
        }
        _toolbarVisible = true;
    }

    private ToolbarButton ButtonAt(Point p)
    {
        if (!_toolbarVisible || !_toolbarRect.Contains(p)) return ToolbarButton.None;
        foreach (var kv in _buttonRects)
            if (kv.Value.Contains(p)) return kv.Key;
        return ToolbarButton.None;
    }

    private bool InToolbar(Point p) => _toolbarVisible && ToolbarGroups().Any(r => r.Contains(p));

    private void HandleToolbarClick(ToolbarButton b)
    {
        switch (b)
        {
            case ToolbarButton.Pointer: ToggleTool(AnnotationTool.Pointer); break;
            case ToolbarButton.Arrow: ToggleTool(AnnotationTool.Arrow); break;
            case ToolbarButton.Rectangle: ToggleTool(AnnotationTool.Rectangle); break;
            case ToolbarButton.Focus: ToggleTool(AnnotationTool.FocusDim); break;
            case ToolbarButton.Undo: UndoLastAnnotation(); break;
            case ToolbarButton.Copy: CommitCopy(); break;
            case ToolbarButton.Timer: CommitTimedCopy(); break;
            case ToolbarButton.CopyText: CommitCopyText(); break;
        }
    }

    private void ToggleTool(AnnotationTool t)
    {
        _tool = _tool == t ? null : t;
        _selectedAnnotation = null;
        Invalidate();
    }

    private void SetTool(AnnotationTool t)
    {
        _tool = t;
        _selectedAnnotation = null;
        Invalidate();
    }

    // ------------------------------------------------------------------ mouse

    protected override void OnMouseDown(MouseEventArgs e)
    {
        _controller.BumpAutoKill();
        if (e.Button == MouseButtons.Right)
        {
            // Right-click: back out of the current selection, or cancel entirely.
            if (_selection != null) ResetSelection();
            else _controller.Cancel();
            return;
        }
        if (e.Button != MouseButtons.Left) return;
        var p = Clamp(e.Location);

        var tb = ButtonAt(e.Location);
        if (tb != ToolbarButton.None)
        {
            _pressedButton = tb;
            Invalidate();
            return;
        }
        if (InToolbar(e.Location)) return;

        switch (_phase)
        {
            case Phase.AwaitingSelection:
            case Phase.Selecting:
                StartNewSelection(p);
                break;
            default:
                var sel = _selection!.Value;
                bool inside = sel.Contains(p);
                if (inside && _tool == AnnotationTool.Pointer)
                {
                    PointerMouseDown(p);
                }
                else if (inside && _tool is { } t && t != AnnotationTool.Pointer)
                {
                    _selectedAnnotation = null;
                    _phase = Phase.Annotating;
                    _annDragStart = p;
                    _annDragCurrent = p;
                    Invalidate();
                }
                else if (!inside)
                {
                    _pendingRestoreSelection = _selection;
                    _pendingRestoreAnnotations = _annotations.Select(a => a.Clone()).ToList();
                    _annotations.Clear();
                    _selection = null;
                    _toolbarVisible = false;
                    _tool = null;
                    StartNewSelection(p);
                }
                break;
        }
    }

    private void StartNewSelection(Point p)
    {
        _phase = Phase.Selecting;
        _selDragStart = p;
        _selDragCurrent = p;
        _selectedAnnotation = null;
        _toolbarVisible = false;
        _controller.SelectionStarted(this);
        Invalidate();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var p = Clamp(e.Location);
        if (e.Button == MouseButtons.Left) _controller.BumpAutoKill();

        if (_pressedButton == ToolbarButton.None)
        {
            var hover = ButtonAt(e.Location);
            if (hover != _hoverButton)
            {
                _hoverButton = hover;
                Invalidate(Rectangle.Inflate(_toolbarRect, (int)(220 * Scale), (int)(60 * Scale)));
            }
        }

        switch (_phase)
        {
            case Phase.Selecting when e.Button == MouseButtons.Left:
                var old = CurrentSelection;
                _selDragCurrent = p;
                InvalidateSelectionChange(old, CurrentSelection);
                break;
            case Phase.Annotating when e.Button == MouseButtons.Left:
                _annDragCurrent = ClampToSelection(p);
                InvalidateSelectionArea();
                break;
            case Phase.EditingAnnotation when e.Button == MouseButtons.Left:
                ApplyControlPointDrag(ClampToSelection(p));
                InvalidateSelectionArea();
                break;
        }
        UpdateCursor(e.Location);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        _controller.BumpAutoKill();
        var p = Clamp(e.Location);

        if (_pressedButton != ToolbarButton.None)
        {
            var pressed = _pressedButton;
            _pressedButton = ToolbarButton.None;
            Invalidate();
            if (ButtonAt(e.Location) == pressed) HandleToolbarClick(pressed);
            return;
        }

        switch (_phase)
        {
            case Phase.Selecting:
            {
                _selDragCurrent = p;
                var rect = RectFrom(_selDragStart!.Value, p);
                if (rect.Width >= MinSelectionSide && rect.Height >= MinSelectionSide)
                {
                    _selection = rect;
                    _annotations.Clear();
                    _phase = Phase.Idle;
                    PositionToolbar(rect);
                    _pendingRestoreSelection = null;
                    _pendingRestoreAnnotations = new();
                }
                else if (_pendingRestoreSelection is { } restore)
                {
                    Sounds.Beep();
                    _selection = restore;
                    _annotations.Clear();
                    _annotations.AddRange(_pendingRestoreAnnotations);
                    _phase = Phase.Idle;
                    PositionToolbar(restore);
                    _pendingRestoreSelection = null;
                    _pendingRestoreAnnotations = new();
                }
                else
                {
                    if (rect.Width > 0 || rect.Height > 0) Sounds.Beep();
                    _selection = null;
                    _phase = Phase.AwaitingSelection;
                }
                _selDragStart = _selDragCurrent = null;
                Invalidate();
                break;
            }
            case Phase.Annotating:
            {
                _annDragCurrent = ClampToSelection(p);
                if (_annDragStart is { } s && _annDragCurrent is { } c && _tool is { } t && t != AnnotationTool.Pointer)
                {
                    float dx = c.X - s.X, dy = c.Y - s.Y;
                    bool add = t == AnnotationTool.Arrow
                        ? MathF.Sqrt(dx * dx + dy * dy) >= 3 * Scale
                        : Math.Abs(dx) >= 8 * Scale && Math.Abs(dy) >= 8 * Scale;
                    if (add) _annotations.Add(new Annotation(KindFor(t), s, c));
                }
                _annDragStart = _annDragCurrent = null;
                _phase = Phase.Idle;
                Invalidate();
                break;
            }
            case Phase.EditingAnnotation:
                _activeControlPoint = ControlPoint.None;
                _moveLast = null;
                _phase = Phase.Idle;
                Invalidate();
                break;
        }
        UpdateCursor(e.Location);
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        if (_hoverButton != ToolbarButton.None)
        {
            _hoverButton = ToolbarButton.None;
            Invalidate();
        }
    }

    private void UpdateCursor(Point p)
    {
        Cursor want = Cursors.Cross;
        if (InToolbar(p)) want = Cursors.Default;
        else if (_selection is { } sel && sel.Contains(p) && _tool == AnnotationTool.Pointer)
        {
            want = Cursors.Default;
            if (_selectedAnnotation is int idx && idx < _annotations.Count && HitControlPoint(p, _annotations[idx]) != ControlPoint.None)
                want = Cursors.Hand;
            else if (AnnotationIndexAt(p) != null)
                want = Cursors.SizeAll;
        }
        if (Cursor != want) Cursor = want;
    }

    private void InvalidateSelectionChange(Rectangle? a, Rectangle? b)
    {
        // Badge sits just outside the selection; pad generously.
        int pad = (int)(40 * Scale);
        Rectangle area = Rectangle.Empty;
        if (a is { } ra) area = Rectangle.Inflate(ra, pad, pad);
        if (b is { } rb) area = area.IsEmpty ? Rectangle.Inflate(rb, pad, pad) : Rectangle.Union(area, Rectangle.Inflate(rb, pad, pad));
        if (area.IsEmpty) Invalidate(); else Invalidate(area);
    }

    private void InvalidateSelectionArea()
    {
        if (_selection is { } s) Invalidate(Rectangle.Inflate(s, (int)(30 * Scale), (int)(30 * Scale)));
        else Invalidate();
    }

    // ------------------------------------------------------------------ annotation editing

    private static AnnotationKind KindFor(AnnotationTool t) => t switch
    {
        AnnotationTool.Arrow => AnnotationKind.Arrow,
        AnnotationTool.Rectangle => AnnotationKind.Rectangle,
        _ => AnnotationKind.FocusDim
    };

    private static IEnumerable<(ControlPoint, PointF)> ControlPoints(Annotation a)
    {
        if (a.Kind == AnnotationKind.Arrow)
        {
            yield return (ControlPoint.ArrowStart, a.Start);
            yield return (ControlPoint.ArrowEnd, a.End);
            yield break;
        }
        var r = a.Rect;
        yield return (ControlPoint.Corner0, new PointF(r.Left, r.Top));
        yield return (ControlPoint.Corner1, new PointF(r.Right, r.Top));
        yield return (ControlPoint.Corner2, new PointF(r.Right, r.Bottom));
        yield return (ControlPoint.Corner3, new PointF(r.Left, r.Bottom));
    }

    private ControlPoint HitControlPoint(PointF p, Annotation a)
    {
        float hr = HitRadius;
        foreach (var (cp, pt) in ControlPoints(a))
        {
            float dx = p.X - pt.X, dy = p.Y - pt.Y;
            if (dx * dx + dy * dy <= hr * hr) return cp;
        }
        return ControlPoint.None;
    }

    private int? AnnotationIndexAt(PointF p)
    {
        for (int i = _annotations.Count - 1; i >= 0; i--)
        {
            var a = _annotations[i];
            bool hit = a.Kind == AnnotationKind.Arrow
                ? DistanceToSegment(p, a.Start, a.End) <= 10 * Scale
                : RectangleF.Inflate(a.Rect, 6 * Scale, 6 * Scale).Contains(p);
            if (hit) return i;
        }
        return null;
    }

    private static float DistanceToSegment(PointF p, PointF a, PointF b)
    {
        float dx = b.X - a.X, dy = b.Y - a.Y;
        float lenSq = dx * dx + dy * dy;
        if (lenSq < 0.001f) return MathF.Sqrt((p.X - a.X) * (p.X - a.X) + (p.Y - a.Y) * (p.Y - a.Y));
        float t = Math.Clamp(((p.X - a.X) * dx + (p.Y - a.Y) * dy) / lenSq, 0, 1);
        float px = a.X + t * dx, py = a.Y + t * dy;
        return MathF.Sqrt((p.X - px) * (p.X - px) + (p.Y - py) * (p.Y - py));
    }

    private void PointerMouseDown(PointF p)
    {
        if (_selectedAnnotation is int idx && idx < _annotations.Count)
        {
            var cp = HitControlPoint(p, _annotations[idx]);
            if (cp != ControlPoint.None)
            {
                _activeControlPoint = cp;
                _moveLast = null;
                _phase = Phase.EditingAnnotation;
                Invalidate();
                return;
            }
        }
        if (AnnotationIndexAt(p) is int hit)
        {
            _selectedAnnotation = hit;
            _activeControlPoint = ControlPoint.Move;
            _moveLast = p;
            _phase = Phase.EditingAnnotation;
            Invalidate();
            return;
        }
        _selectedAnnotation = null;
        _activeControlPoint = ControlPoint.None;
        _moveLast = null;
        Invalidate();
    }

    private void ApplyControlPointDrag(PointF p)
    {
        if (_selectedAnnotation is not int idx || idx >= _annotations.Count) return;
        var a = _annotations[idx];
        switch (_activeControlPoint)
        {
            case ControlPoint.Move:
                if (_moveLast is not { } last) return;
                float dx = p.X - last.X, dy = p.Y - last.Y;
                if (Math.Abs(dx) > 0.001f || Math.Abs(dy) > 0.001f)
                    _annotations[idx] = Translate(a, dx, dy, _selection!.Value);
                _moveLast = p;
                break;
            case ControlPoint.ArrowStart: a.Start = p; break;
            case ControlPoint.ArrowEnd: a.End = p; break;
            case ControlPoint.Corner0:
            case ControlPoint.Corner1:
            case ControlPoint.Corner2:
            case ControlPoint.Corner3:
                var corners = ControlPoints(a).Select(c => c.Item2).ToArray();
                int corner = _activeControlPoint - ControlPoint.Corner0;
                var opposite = corners[(corner + 2) % 4];
                a.Start = p;
                a.End = opposite;
                // After normalising, the dragged corner index may change; track it.
                var r = a.Rect;
                _activeControlPoint = (p.X <= r.Left + 0.01f, p.Y <= r.Top + 0.01f) switch
                {
                    (true, true) => ControlPoint.Corner0,
                    (false, true) => ControlPoint.Corner1,
                    (false, false) => ControlPoint.Corner2,
                    (true, false) => ControlPoint.Corner3,
                };
                break;
        }
    }

    private RectangleF AnnotationBounds(Annotation a) =>
        a.Kind == AnnotationKind.Arrow ? RectangleF.Inflate(a.Rect, 22 * Scale, 22 * Scale) : a.Rect;

    private Annotation Translate(Annotation a, float dx, float dy, Rectangle sel)
    {
        var moved = a.Offset(dx, dy);
        var b = AnnotationBounds(moved);
        float fx = 0, fy = 0;
        if (b.Left < sel.Left) fx = sel.Left - b.Left;
        if (b.Right > sel.Right) fx = sel.Right - b.Right;
        if (b.Top < sel.Top) fy = sel.Top - b.Top;
        if (b.Bottom > sel.Bottom) fy = sel.Bottom - b.Bottom;
        return fx != 0 || fy != 0 ? moved.Offset(fx, fy) : moved;
    }

    private bool UndoLastAnnotation()
    {
        if (_annotations.Count == 0) return false;
        int removed = _annotations.Count - 1;
        _annotations.RemoveAt(removed);
        if (_selectedAnnotation == removed) _selectedAnnotation = null;
        Invalidate();
        return true;
    }

    private bool DeleteSelectedAnnotation()
    {
        if (_selectedAnnotation is not int idx || idx >= _annotations.Count) return false;
        _annotations.RemoveAt(idx);
        _selectedAnnotation = null;
        Invalidate();
        return true;
    }

    private async void FlashUndo()
    {
        _undoFlash = true;
        Invalidate(_toolbarRect);
        await Task.Delay(90);
        _undoFlash = false;
        Invalidate(_toolbarRect);
    }

    // ------------------------------------------------------------------ commit actions

    private void CommitCopy()
    {
        if (_selection == null) { Sounds.Beep(); return; }
        _controller.CopySelection(this);
    }

    private void CommitCopyText()
    {
        if (_selection == null) { Sounds.Beep(); return; }
        _controller.CopyText(this);
    }

    private void CommitTimedCopy()
    {
        if (_selection == null) { Sounds.Beep(); return; }
        _toolbarVisible = false;
        _hoverButton = ToolbarButton.None;
        _controller.StartTimedCapture(this);
    }

    // ------------------------------------------------------------------ keyboard

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        _controller.BumpAutoKill();
        var key = keyData & Keys.KeyCode;
        bool ctrl = (keyData & Keys.Control) != 0;

        if (key == Keys.Escape) { _controller.Cancel(); return true; }

        if (key == Keys.Enter || (ctrl && key == Keys.C)) { CommitCopy(); return true; }

        if (ctrl && key == Keys.Z)
        {
            if (UndoLastAnnotation()) FlashUndo();
            return true;
        }

        if (_selection != null && _tool == AnnotationTool.Pointer && (key == Keys.Delete || key == Keys.Back))
        {
            if (DeleteSelectedAnnotation()) return true;
        }

        if (_selection != null && !ctrl && (keyData & Keys.Alt) == 0 && _phase is Phase.Idle or Phase.Annotating or Phase.EditingAnnotation)
        {
            switch (key)
            {
                case Keys.V: SetTool(AnnotationTool.Pointer); return true;
                case Keys.A: SetTool(AnnotationTool.Arrow); return true;
                case Keys.R: SetTool(AnnotationTool.Rectangle); return true;
                case Keys.F: SetTool(AnnotationTool.FocusDim); return true;
            }
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    // ------------------------------------------------------------------ countdown layer

    /// <summary>
    /// Renders the countdown overlay for UpdateLayeredWindow: dim outside the selection, a fully
    /// transparent hole over it (so the live screen shows through), annotations, and the number.
    /// </summary>
    public Bitmap RenderCountdownLayer(int? remaining)
    {
        var bmp = new Bitmap(ScreenBounds.Width, ScreenBounds.Height, PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bmp);
        g.Clear(Color.FromArgb(140, 0, 0, 0));
        if (_selection is { } s)
        {
            g.CompositingMode = CompositingMode.SourceCopy;
            using (var clear = new SolidBrush(Color.FromArgb(0, 0, 0, 0)))
                g.FillRectangle(clear, s);
            g.CompositingMode = CompositingMode.SourceOver;
            if (_annotations.Count > 0) AnnotationRenderer.DrawAll(g, _annotations, s, Scale, preview: true);
            using (var border = new Pen(Color.FromArgb(230, 255, 255, 255), 1))
                g.DrawRectangle(border, s.X - 1, s.Y - 1, s.Width + 1, s.Height + 1);

            if (remaining is int n)
            {
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                using var font = UiFont(30, FontStyle.Bold);
                string text = n.ToString();
                var size = g.MeasureString(text, font);
                float side = Math.Max(48 * Scale, Math.Max(size.Width, size.Height) + 14 * Scale);
                float x = s.X + s.Width / 2f - side / 2f;
                float y = s.Bottom + 12 * Scale;
                if (y + side > ScreenBounds.Height - 4 * Scale)
                {
                    y = s.Y - side - 12 * Scale;
                    if (y < 4 * Scale) y = Math.Max(4 * Scale, s.Bottom - side - 12 * Scale);
                }
                x = Math.Clamp(x, 4 * Scale, ScreenBounds.Width - side - 4 * Scale);
                var box = new RectangleF(x, y, side, side);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                using (var path = Icons.RoundRect(box, 8 * Scale))
                using (var b = new SolidBrush(Color.FromArgb(200, 0, 0, 0)))
                    g.FillPath(b, path);
                g.DrawString(text, font, Brushes.White, x + (side - size.Width) / 2, y + (side - size.Height) / 2);

                using var hintFont = UiFont(12, FontStyle.Bold);
                const string hint = "Esc to cancel";
                var hs = g.MeasureString(hint, hintFont);
                g.DrawString(hint, hintFont, Brushes.White, x + side / 2 - hs.Width / 2, y + side + 4 * Scale);
            }
        }
        return bmp;
    }

    // ------------------------------------------------------------------ helpers

    private Point Clamp(Point p) => new(
        Math.Clamp(p.X, 0, ClientSize.Width),
        Math.Clamp(p.Y, 0, ClientSize.Height));

    private PointF ClampToSelection(PointF p)
    {
        if (_selection is not { } s) return p;
        return new PointF(Math.Clamp(p.X, s.Left, s.Right), Math.Clamp(p.Y, s.Top, s.Bottom));
    }

    private static Rectangle RectFrom(Point a, Point b) => Rectangle.FromLTRB(
        Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));

    private static Bitmap ToPArgb(Bitmap src)
    {
        var dst = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(dst);
        g.CompositingMode = CompositingMode.SourceCopy;
        g.DrawImageUnscaled(src, 0, 0);
        return dst;
    }

    private static Bitmap MakeDimmed(Bitmap src, float amount)
    {
        var dst = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(dst);
        g.CompositingMode = CompositingMode.SourceCopy;
        g.DrawImageUnscaled(src, 0, 0);
        g.CompositingMode = CompositingMode.SourceOver;
        using var b = new SolidBrush(Color.FromArgb((int)(255 * amount), 0, 0, 0));
        g.FillRectangle(b, 0, 0, src.Width, src.Height);
        return dst;
    }
}
