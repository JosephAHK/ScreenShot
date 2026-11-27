using System.Drawing.Drawing2D;
using System.Drawing.Text;

namespace ScreenShot;

/// <summary>
/// Tray flyout: header (Capture / Open Folder) + 3-column grid of recent screenshots.
/// Hover a thumbnail for Copy / Delete; double-click opens it; drag it out as a file;
/// right-click for Open / Copy / Show in Explorer / Delete.
/// </summary>
internal sealed class FlyoutForm : Form
{
    private const int LogicalWidth = 360;
    private const int LogicalHeight = 440;

    private readonly Action _onCapture;
    private readonly HeaderBar _header;
    private readonly ThumbGrid _grid;

    public FlyoutForm(Action onCapture, string hotkeyLabel)
    {
        _onCapture = onCapture;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96, 96);
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = Theme.Background;
        ClientSize = new Size(LogicalWidth, LogicalHeight);
        Text = "ScreenShot";
        KeyPreview = true;

        _header = new HeaderBar(hotkeyLabel)
        {
            Dock = DockStyle.Top,
            Height = 44,
        };
        _header.CaptureClicked += () => { Hide(); _onCapture(); };
        _header.FolderClicked += () => { Hide(); Shell.Open(CapturesStore.Shared.FolderPath); };

        var divider = new Panel { Dock = DockStyle.Top, Height = 1, BackColor = Theme.Divider };

        _grid = new ThumbGrid(hotkeyLabel) { Dock = DockStyle.Fill };
        _grid.RequestHide += Hide;

        Controls.Add(_grid);
        Controls.Add(divider);
        Controls.Add(_header);

        CapturesStore.Shared.Changed += () =>
        {
            if (IsHandleCreated) BeginInvoke(() => _grid.SetItems(CapturesStore.Shared.Items));
        };
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= Native.WS_EX_TOOLWINDOW;
            cp.ClassStyle |= 0x00020000; // CS_DROPSHADOW
            return cp;
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        int dark = 1, round = 2; // DWMWCP_ROUND (Windows 11; ignored on 10)
        Native.DwmSetWindowAttribute(Handle, Native.DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));
        Native.DwmSetWindowAttribute(Handle, Native.DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        using var pen = new Pen(Theme.Border);
        e.Graphics.DrawRectangle(pen, 0, 0, ClientSize.Width - 1, ClientSize.Height - 1);
    }

    public void ShowNearTray()
    {
        CapturesStore.Shared.Refresh();
        _grid.SetItems(CapturesStore.Shared.Items);

        var cursor = Cursor.Position;
        var screen = Screen.FromPoint(cursor);
        var wa = screen.WorkingArea;
        var b = screen.Bounds;

        if (!Visible) Show(); // create on the right monitor so DPI scaling applies before we measure
        var size = Size;
        int margin = (int)(12 * DeviceDpi / 96f);
        int x = Math.Clamp(cursor.X - size.Width / 2, wa.Left + margin, wa.Right - size.Width - margin);
        int y;
        if (wa.Bottom < b.Bottom) y = wa.Bottom - size.Height - margin;      // taskbar bottom
        else if (wa.Top > b.Top) y = wa.Top + margin;                         // taskbar top
        else y = Math.Clamp(cursor.Y - size.Height - margin, wa.Top + margin, wa.Bottom - size.Height - margin);
        if (wa.Right < b.Right) x = wa.Right - size.Width - margin;           // taskbar right
        else if (wa.Left > b.Left) x = wa.Left + margin;                      // taskbar left

        Location = new Point(x, y);
        Activate();
        Native.SetForegroundWindow(Handle);
        _grid.Focus();
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        if (!_grid.IsShowingMenu) Hide();
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Escape) { Hide(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        base.OnFormClosing(e);
    }
}

internal static class Theme
{
    public static readonly Color Background = Color.FromArgb(32, 32, 32);
    public static readonly Color Surface = Color.FromArgb(44, 44, 44);
    public static readonly Color Divider = Color.FromArgb(56, 56, 56);
    public static readonly Color Border = Color.FromArgb(70, 70, 70);
    public static readonly Color Text = Color.FromArgb(240, 240, 240);
    public static readonly Color Secondary = Color.FromArgb(160, 160, 160);
    public static readonly Color Tertiary = Color.FromArgb(110, 110, 110);
    public static readonly Color Accent = Color.FromArgb(76, 194, 255);
    public static readonly Color Green = Color.FromArgb(48, 209, 88);
}

/// <summary>Two borderless "Capture" / "Open Folder" buttons.</summary>
internal sealed class HeaderBar : Control
{
    public event Action? CaptureClicked;
    public event Action? FolderClicked;

    private readonly string _captureLabel;
    private Rectangle _captureRect, _folderRect;
    private int _hover = -1;
    private int _pressed = -1;

    public HeaderBar(string hotkeyLabel)
    {
        _captureLabel = $"Capture ({hotkeyLabel})";
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        BackColor = Theme.Background;
        Cursor = Cursors.Default;
    }

    private float S => DeviceDpi / 96f;

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        using var font = new Font("Segoe UI", 9.5f * S, FontStyle.Regular, GraphicsUnit.Point);
        using var fontPx = new Font("Segoe UI", 13f * S, GraphicsUnit.Pixel);

        int pad = (int)(8 * S);
        var capSize = TextRenderer.MeasureText(_captureLabel, fontPx);
        var folSize = TextRenderer.MeasureText("Open Folder", fontPx);
        int icon = (int)(16 * S), gap = (int)(6 * S), h = (int)(30 * S);
        int y = (Height - h) / 2;
        _captureRect = new Rectangle(pad, y, icon + gap + capSize.Width + pad * 2, h);
        int fw = icon + gap + folSize.Width + pad * 2;
        _folderRect = new Rectangle(Width - pad - fw, y, fw, h);

        DrawButton(g, _captureRect, Icons.Glyph.Camera, _captureLabel, fontPx, 0);
        DrawButton(g, _folderRect, Icons.Glyph.Folder, "Open Folder", fontPx, 1);
    }

    private void DrawButton(Graphics g, Rectangle r, Icons.Glyph glyph, string text, Font font, int index)
    {
        if (_hover == index || _pressed == index)
        {
            using var path = Icons.RoundRect(r, 5 * S);
            using var b = new SolidBrush(_pressed == index ? Color.FromArgb(60, 255, 255, 255) : Color.FromArgb(28, 255, 255, 255));
            g.FillPath(b, path);
        }
        int pad = (int)(8 * S), icon = (int)(16 * S), gap = (int)(6 * S);
        Icons.Draw(g, glyph, new RectangleF(r.X + pad, r.Y + (r.Height - icon) / 2f, icon, icon), Theme.Accent, icon);
        var textRect = new Rectangle(r.X + pad + icon + gap, r.Y, r.Width - pad * 2 - icon - gap + pad, r.Height);
        TextRenderer.DrawText(g, text, font, textRect, Theme.Accent,
            TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.NoPadding);
    }

    private int HitIndex(Point p) => _captureRect.Contains(p) ? 0 : _folderRect.Contains(p) ? 1 : -1;

    protected override void OnMouseMove(MouseEventArgs e)
    {
        int h = HitIndex(e.Location);
        if (h != _hover) { _hover = h; Cursor = h >= 0 ? Cursors.Hand : Cursors.Default; Invalidate(); }
    }

    protected override void OnMouseLeave(EventArgs e) { _hover = -1; _pressed = -1; Invalidate(); }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left) { _pressed = HitIndex(e.Location); Invalidate(); }
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        int pressed = _pressed;
        _pressed = -1;
        Invalidate();
        if (e.Button != MouseButtons.Left || pressed < 0 || HitIndex(e.Location) != pressed) return;
        if (pressed == 0) CaptureClicked?.Invoke(); else FolderClicked?.Invoke();
    }
}

/// <summary>Owner-drawn, scrollable 3-column grid of square thumbnails.</summary>
internal sealed class ThumbGrid : ScrollableControl
{
    public event Action? RequestHide;

    private readonly string _hotkeyLabel;
    private List<string> _items = new();
    private readonly Dictionary<string, (DateTime Stamp, Bitmap? Thumb)> _thumbs = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _loading = new(StringComparer.OrdinalIgnoreCase);
    private int _hoverIndex = -1;
    private int _hoverButton = -1; // 0 copy, 1 delete
    private readonly Dictionary<string, DateTime> _copiedUntil = new(StringComparer.OrdinalIgnoreCase);
    private readonly System.Windows.Forms.Timer _animTimer = new() { Interval = 50 };
    private Point _mouseDownAt;
    private int _mouseDownIndex = -1;
    private readonly ToolTip _tip = new() { InitialDelay = 600 };
    private string? _tipText;

    public bool IsShowingMenu { get; private set; }

    public ThumbGrid(string hotkeyLabel)
    {
        _hotkeyLabel = hotkeyLabel;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint |
                 ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
        BackColor = Theme.Background;
        AutoScroll = true;
        _animTimer.Tick += (_, _) =>
        {
            var now = DateTime.UtcNow;
            foreach (var k in _copiedUntil.Where(kv => kv.Value < now).Select(kv => kv.Key).ToList())
                _copiedUntil.Remove(k);
            if (_copiedUntil.Count == 0) _animTimer.Stop();
            Invalidate();
        };
    }

    private float S => DeviceDpi / 96f;
    private int Pad => (int)(10 * S);
    private int Spacing => (int)(8 * S);
    private int Cell => Math.Max(1, (ClientSize.Width - Pad * 2 - Spacing * 2) / 3);

    public void SetItems(IReadOnlyList<string> items)
    {
        _items = items.ToList();
        var keep = new HashSet<string>(_items, StringComparer.OrdinalIgnoreCase);
        foreach (var stale in _thumbs.Keys.Where(k => !keep.Contains(k)).ToList())
        {
            _thumbs[stale].Thumb?.Dispose();
            _thumbs.Remove(stale);
        }
        UpdateScrollSize();
        _hoverIndex = -1;
        Invalidate();
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        UpdateScrollSize();
    }

    private void UpdateScrollSize()
    {
        int rows = (_items.Count + 2) / 3;
        int h = rows == 0 ? 0 : Pad * 2 + rows * Cell + (rows - 1) * Spacing;
        AutoScrollMinSize = new Size(0, h);
    }

    private Rectangle CellRect(int i)
    {
        int col = i % 3, row = i / 3;
        return new Rectangle(Pad + col * (Cell + Spacing), Pad + row * (Cell + Spacing) + AutoScrollPosition.Y, Cell, Cell);
    }

    private int IndexAt(Point p)
    {
        for (int i = 0; i < _items.Count; i++)
            if (CellRect(i).Contains(p)) return i;
        return -1;
    }

    private (Rectangle Copy, Rectangle Delete, Rectangle Bar) ButtonRects(Rectangle cell)
    {
        int barH = (int)(34 * S), pad = (int)(6 * S), gap = (int)(6 * S), bh = (int)(24 * S);
        var bar = new Rectangle(cell.X, cell.Bottom - barH, cell.Width, barH);
        int bw = (cell.Width - pad * 2 - gap) / 2;
        int by = cell.Bottom - pad - bh + (int)(1 * S);
        return (new Rectangle(cell.X + pad, by, bw, bh), new Rectangle(cell.X + pad + bw + gap, by, bw, bh), bar);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;

        if (_items.Count == 0)
        {
            DrawEmpty(g);
            return;
        }

        float radius = 6 * S;
        for (int i = 0; i < _items.Count; i++)
        {
            var r = CellRect(i);
            if (!r.IntersectsWith(e.ClipRectangle)) continue;
            var path = _items[i];
            using var clip = Icons.RoundRect(r, radius);

            var thumb = GetThumb(path, r.Width);
            var state = g.Save();
            g.SetClip(clip);
            using (var bg = new SolidBrush(Theme.Surface)) g.FillRectangle(bg, r);
            if (thumb != null) g.DrawImage(thumb, r);

            bool hover = i == _hoverIndex;
            bool copied = _copiedUntil.ContainsKey(path);
            if (hover || copied)
            {
                var (copy, del, bar) = ButtonRects(r);
                using (var grad = new LinearGradientBrush(new Rectangle(bar.X, bar.Y - 1, bar.Width, bar.Height + 2),
                           Color.FromArgb(0, 0, 0, 0), Color.FromArgb(180, 0, 0, 0), 90f))
                    g.FillRectangle(grad, bar);
                DrawHoverButton(g, copy, Icons.Glyph.Copy, _hoverIndex == i && _hoverButton == 0);
                DrawHoverButton(g, del, Icons.Glyph.Trash, _hoverIndex == i && _hoverButton == 1);
            }
            if (copied)
            {
                using (var dim = new SolidBrush(Color.FromArgb(102, 0, 0, 0))) g.FillRectangle(dim, r);
                float iconSize = Math.Min(r.Width, r.Height) * 0.32f;
                var circle = new RectangleF(r.X + (r.Width - iconSize) / 2, r.Y + (r.Height - iconSize) / 2 - 8 * S, iconSize, iconSize);
                using (var green = new SolidBrush(Theme.Green)) g.FillEllipse(green, circle);
                Icons.Draw(g, Icons.Glyph.Check, circle, Color.White, iconSize * 0.7f);
                using var f = new Font("Segoe UI", 11f * S, FontStyle.Bold, GraphicsUnit.Pixel);
                var ts = g.MeasureString("Copied", f);
                g.DrawString("Copied", f, Brushes.White, r.X + (r.Width - ts.Width) / 2, circle.Bottom + 3 * S);
            }
            g.Restore(state);

            Color borderColor = copied ? Theme.Green : hover ? Theme.Accent : Color.FromArgb(40, 255, 255, 255);
            float bw = copied || hover ? 2 * S : 1;
            using var pen = new Pen(borderColor, bw) { Alignment = PenAlignment.Inset };
            using var borderPath = Icons.RoundRect(new RectangleF(r.X + bw / 2, r.Y + bw / 2, r.Width - bw, r.Height - bw), radius);
            g.DrawPath(pen, borderPath);
        }
    }

    private void DrawHoverButton(Graphics g, Rectangle r, Icons.Glyph glyph, bool hot)
    {
        using var path = Icons.RoundRect(r, 5 * S);
        using var fill = new SolidBrush(Color.FromArgb(hot ? 56 : 26, 255, 255, 255));
        using var stroke = new Pen(Color.FromArgb(46, 255, 255, 255), 1);
        g.FillPath(fill, path);
        g.DrawPath(stroke, path);
        Icons.Draw(g, glyph, r, Color.White, 12 * S);
    }

    private void DrawEmpty(Graphics g)
    {
        float icon = 40 * S;
        float cy = ClientSize.Height / 2f;
        Icons.Draw(g, Icons.Glyph.Photo, new RectangleF((ClientSize.Width - icon) / 2, cy - icon - 14 * S, icon, icon), Theme.Secondary, icon);
        using var f1 = new Font("Segoe UI", 13f * S, GraphicsUnit.Pixel);
        using var f2 = new Font("Segoe UI", 11.5f * S, GraphicsUnit.Pixel);
        var flags = TextFormatFlags.HorizontalCenter | TextFormatFlags.Top;
        TextRenderer.DrawText(g, "No screenshots yet", f1, new Rectangle(0, (int)(cy - 2 * S), ClientSize.Width, (int)(22 * S)), Theme.Secondary, flags);
        TextRenderer.DrawText(g, $"Press {_hotkeyLabel} anywhere to capture", f2, new Rectangle(0, (int)(cy + 20 * S), ClientSize.Width, (int)(20 * S)), Theme.Tertiary, flags);
    }

    // -------------------------------------------------------------- thumbnails

    private Bitmap? GetThumb(string path, int size)
    {
        DateTime stamp;
        try { stamp = File.GetLastWriteTimeUtc(path); } catch { return null; }
        if (_thumbs.TryGetValue(path, out var t) && t.Stamp == stamp && t.Thumb != null && t.Thumb.Width >= size)
            return t.Thumb;
        if (_loading.Add(path))
        {
            int target = Math.Max(size, 64);
            Task.Run(() => MakeThumb(path, target)).ContinueWith(task =>
            {
                if (IsDisposed) { task.Result?.Dispose(); return; }
                try
                {
                    BeginInvoke(() =>
                    {
                        _loading.Remove(path);
                        if (_thumbs.TryGetValue(path, out var oldT)) oldT.Thumb?.Dispose();
                        _thumbs[path] = (stamp, task.Result);
                        Invalidate();
                    });
                }
                catch { task.Result?.Dispose(); }
            });
        }
        return t.Thumb; // stale or null while loading
    }

    /// <summary>Aspect-fill square thumbnail.</summary>
    private static Bitmap? MakeThumb(string path, int size)
    {
        using var src = CapturesStore.LoadUnlocked(path);
        if (src == null) return null;
        var thumb = new Bitmap(size, size);
        using var g = Graphics.FromImage(thumb);
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        float scale = Math.Max((float)size / src.Width, (float)size / src.Height);
        float w = src.Width * scale, h = src.Height * scale;
        g.DrawImage(src, (size - w) / 2, (size - h) / 2, w, h);
        return thumb;
    }

    // -------------------------------------------------------------- mouse

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (e.Button == MouseButtons.Left && _mouseDownIndex >= 0)
        {
            var drag = SystemInformation.DragSize;
            if (Math.Abs(e.X - _mouseDownAt.X) > drag.Width || Math.Abs(e.Y - _mouseDownAt.Y) > drag.Height)
            {
                var path = _items[_mouseDownIndex];
                _mouseDownIndex = -1;
                var data = new DataObject(DataFormats.FileDrop, new[] { path });
                DoDragDrop(data, DragDropEffects.Copy);
                return;
            }
        }

        int idx = IndexAt(e.Location);
        int btn = -1;
        if (idx >= 0)
        {
            var (copy, del, _) = ButtonRects(CellRect(idx));
            btn = copy.Contains(e.Location) ? 0 : del.Contains(e.Location) ? 1 : -1;
        }
        if (idx != _hoverIndex || btn != _hoverButton)
        {
            _hoverIndex = idx;
            _hoverButton = btn;
            Cursor = btn >= 0 ? Cursors.Hand : Cursors.Default;
            Invalidate();
        }

        string? tip = btn == 0 ? "Copy to clipboard" : btn == 1 ? "Delete" : idx >= 0 ? Path.GetFileName(_items[idx]) : null;
        if (tip != _tipText)
        {
            _tipText = tip;
            _tip.SetToolTip(this, tip);
        }
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        _hoverIndex = -1;
        _hoverButton = -1;
        Invalidate();
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        Focus();
        _mouseDownAt = e.Location;
        _mouseDownIndex = e.Button == MouseButtons.Left && _hoverButton < 0 ? IndexAt(e.Location) : -1;
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        _mouseDownIndex = -1;
        int idx = IndexAt(e.Location);
        if (idx < 0) return;
        var path = _items[idx];

        if (e.Button == MouseButtons.Right)
        {
            ShowContextMenu(path, e.Location);
            return;
        }
        if (e.Button != MouseButtons.Left) return;

        var (copy, del, _) = ButtonRects(CellRect(idx));
        if (copy.Contains(e.Location)) HandleCopy(path);
        else if (del.Contains(e.Location)) HandleDelete(path);
    }

    protected override void OnMouseDoubleClick(MouseEventArgs e)
    {
        base.OnMouseDoubleClick(e);
        if (e.Button != MouseButtons.Left) return;
        int idx = IndexAt(e.Location);
        if (idx < 0) return;
        var (copy, del, _) = ButtonRects(CellRect(idx));
        if (copy.Contains(e.Location) || del.Contains(e.Location)) return;
        RequestHide?.Invoke();
        Shell.Open(_items[idx]);
    }

    private void ShowContextMenu(string path, Point at)
    {
        var menu = new ContextMenuStrip { Renderer = new ToolStripProfessionalRenderer(new DarkColors()), ForeColor = Theme.Text, ShowImageMargin = false };
        menu.Items.Add("Open", null, (_, _) => { RequestHide?.Invoke(); Shell.Open(path); });
        menu.Items.Add("Copy", null, (_, _) => HandleCopy(path));
        menu.Items.Add("Show in Explorer", null, (_, _) => { RequestHide?.Invoke(); Shell.RevealInExplorer(path); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Delete", null, (_, _) => HandleDelete(path));
        IsShowingMenu = true;
        menu.Closed += (_, _) =>
        {
            IsShowingMenu = false;
            BeginInvoke(() => { if (!FindForm()!.ContainsFocus && Form.ActiveForm != FindForm()) FindForm()!.Hide(); });
        };
        menu.Show(this, at);
    }

    private void HandleCopy(string path)
    {
        try
        {
            ClipboardHelper.SetImageFromFile(path);
            Sounds.Tink();
            _copiedUntil[path] = DateTime.UtcNow.AddMilliseconds(900);
            _animTimer.Start();
            Invalidate();
        }
        catch (Exception ex)
        {
            OverlayController.Log($"copy thumb failed: {ex.Message}");
            Sounds.Beep();
        }
    }

    private void HandleDelete(string path)
    {
        Sounds.Trash();
        CapturesStore.Shared.Delete(path);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            foreach (var t in _thumbs.Values) t.Thumb?.Dispose();
            _thumbs.Clear();
            _animTimer.Dispose();
            _tip.Dispose();
        }
        base.Dispose(disposing);
    }
}

internal sealed class DarkColors : ProfessionalColorTable
{
    public override Color ToolStripDropDownBackground => Theme.Surface;
    public override Color MenuBorder => Theme.Border;
    public override Color MenuItemSelected => Color.FromArgb(64, 64, 64);
    public override Color MenuItemBorder => Color.FromArgb(64, 64, 64);
    public override Color SeparatorDark => Theme.Border;
    public override Color SeparatorLight => Theme.Border;
    public override Color ImageMarginGradientBegin => Theme.Surface;
    public override Color ImageMarginGradientMiddle => Theme.Surface;
    public override Color ImageMarginGradientEnd => Theme.Surface;
}
