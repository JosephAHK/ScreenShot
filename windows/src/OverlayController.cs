using System.Drawing.Imaging;
using Microsoft.Win32;

namespace ScreenShot;

/// <summary>Owns the per-monitor overlays and the capture / copy / save pipeline.</summary>
internal sealed class OverlayController
{
    private const int CountdownSeconds = 5;
    private static readonly TimeSpan InactivityTimeout = TimeSpan.FromSeconds(30);

    private readonly List<OverlayForm> _forms = new();
    private readonly System.Windows.Forms.Timer _autoKill = new();
    private HotkeyManager? _hotkeys;

    private bool _captureInProgress;
    private bool _countdownActive;
    private List<LayeredWindow> _countdownWindows = new();
    private CancellationTokenSource? _countdownCts;
    private OverlayForm? _countdownSource;

    public bool IsActive => _forms.Count > 0 || _countdownActive;

    public OverlayController()
    {
        _autoKill.Interval = (int)InactivityTimeout.TotalMilliseconds;
        _autoKill.Tick += (_, _) => { if (!_countdownActive) Dismiss(); };
        SystemEvents.DisplaySettingsChanged += (_, _) => { if (IsActive) Dismiss(); };
    }

    public void SetHotkeyManager(HotkeyManager hk) => _hotkeys = hk;

    // ------------------------------------------------------------------ lifecycle

    public void Begin()
    {
        Log($"begin (active={IsActive}, countdown={_countdownActive})");
        if (_countdownActive) return;
        if (IsActive) { Dismiss(); return; }

        // Freeze every monitor first, then show the overlays (so they aren't in the shot).
        var screens = Screen.AllScreens;
        var frames = new List<(Rectangle Bounds, Bitmap Frame)>();
        try
        {
            foreach (var s in screens)
                frames.Add((s.Bounds, ScreenCapture.CaptureRect(s.Bounds)));
        }
        catch (Exception ex)
        {
            foreach (var f in frames) f.Frame.Dispose();
            Log($"freeze failed: {ex}");
            Sounds.Beep();
            return;
        }

        foreach (var (bounds, frame) in frames)
        {
            var form = new OverlayForm(this, bounds, frame);
            frame.Dispose();
            _forms.Add(form);
            form.Show();
            form.PlaceOnScreen();
        }
        foreach (var f in _forms) f.Reveal();

        var cursor = Cursor.Position;
        var start = _forms.FirstOrDefault(f => f.ScreenBounds.Contains(cursor)) ?? _forms[0];
        start.ActivateOverlay();
        BumpAutoKill();
    }

    public void BumpAutoKill()
    {
        if (!IsActive) return;
        _autoKill.Stop();
        _autoKill.Start();
    }

    public void Cancel() => Dismiss();

    public void Dismiss()
    {
        _autoKill.Stop();
        EndCountdown(restore: false);
        foreach (var f in _forms)
        {
            f.Hide();
            f.Dispose();
        }
        _forms.Clear();
        _captureInProgress = false;
    }

    public void SelectionStarted(OverlayForm source)
    {
        foreach (var f in _forms)
            if (f != source) f.ResetSelection();
    }

    // ------------------------------------------------------------------ copy image

    public void CopySelection(OverlayForm form)
    {
        if (_captureInProgress || _countdownActive || form.Selection is not { } sel) { Sounds.Beep(); return; }
        if (sel.Width < 4 || sel.Height < 4) { Sounds.Beep(); return; }
        _captureInProgress = true;

        Bitmap image;
        try
        {
            image = form.CompositeFromFrozen();
        }
        catch (Exception ex)
        {
            Log($"composite failed: {ex}");
            Sounds.Beep();
            Dismiss();
            return;
        }
        Dismiss();
        Deliver(image);
    }

    /// <summary>Clipboard + save to the captures folder + sound.</summary>
    private static void Deliver(Bitmap image)
    {
        using (image)
        {
            try
            {
                ClipboardHelper.SetImage(image);
            }
            catch (Exception ex)
            {
                Log($"clipboard failed: {ex}");
            }

            try
            {
                var path = CapturesStore.Shared.Save(image);
                Log($"saved {path}");
                Sounds.Captured();
            }
            catch (Exception ex)
            {
                Log($"save failed: {ex}");
                Sounds.Beep();
                var choice = MessageBox.Show(
                    $"ScreenShot can't save to its captures folder:\n\n{CapturesStore.Shared.FolderPath}\n\n{ex.Message}\n\n" +
                    "The image is still on the clipboard. Open the parent folder?",
                    "ScreenShot", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                if (choice == DialogResult.Yes) Shell.Open(Path.GetDirectoryName(CapturesStore.Shared.FolderPath)!);
            }
        }
    }

    // ------------------------------------------------------------------ OCR

    public async void CopyText(OverlayForm form)
    {
        if (_captureInProgress || _countdownActive || form.Selection is not { } sel) { Sounds.Beep(); return; }
        if (sel.Width < 4 || sel.Height < 4) { Sounds.Beep(); return; }
        _captureInProgress = true;

        Bitmap crop = form.CropFrozen(sel);
        Dismiss();
        try
        {
            string text;
            using (crop)
                text = await OcrService.RecognizeTextAsync(crop);
            if (string.IsNullOrWhiteSpace(text))
            {
                Log("OCR found no text");
                Sounds.Beep();
                return;
            }
            ClipboardHelper.SetText(text);
            Log($"OCR copied {text.Length} chars");
            Sounds.Tink();
        }
        catch (Exception ex)
        {
            Log($"OCR failed: {ex}");
            Sounds.Beep();
            MessageBox.Show($"Text recognition failed:\n\n{ex.Message}", "ScreenShot",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    // ------------------------------------------------------------------ timed capture

    public async void StartTimedCapture(OverlayForm form)
    {
        if (_countdownActive || _captureInProgress || form.Selection is not { } sel) { Sounds.Beep(); return; }
        _countdownActive = true;
        _countdownSource = form;
        _autoKill.Stop();
        var cts = new CancellationTokenSource();
        _countdownCts = cts;

        // Swap each frozen overlay for a click-through live layer.
        foreach (var f in _forms)
        {
            var lw = new LayeredWindow(f.ScreenBounds);
            using (var layer = f.RenderCountdownLayer(f == form ? CountdownSeconds : null))
            {
                lw.Show();
                lw.SetContent(layer);
            }
            _countdownWindows.Add(lw);
        }
        foreach (var f in _forms) f.Hide();
        _hotkeys?.RegisterEscape(() => EndCountdown(restore: true));

        try
        {
            for (int n = CountdownSeconds; n >= 1; n--)
            {
                var srcIdx = _forms.IndexOf(form);
                if (srcIdx >= 0 && srcIdx < _countdownWindows.Count)
                    using (var layer = form.RenderCountdownLayer(n))
                        _countdownWindows[srcIdx].SetContent(layer);
                await Task.Delay(1000, cts.Token);
            }
        }
        catch (TaskCanceledException)
        {
            return;
        }

        if (cts.IsCancellationRequested) return;

        // Hide everything, let DWM repaint, then grab the live pixels.
        var annotations = form.Annotations.Select(a => a.Clone()).ToList();
        var scale = form.Scale;
        var global = new Rectangle(form.ScreenBounds.X + sel.X, form.ScreenBounds.Y + sel.Y, sel.Width, sel.Height);
        CloseCountdownWindows();
        _hotkeys?.UnregisterEscape();
        _countdownActive = false;
        _captureInProgress = true;
        foreach (var f in _forms) { f.Hide(); f.Dispose(); }
        _forms.Clear();

        await Task.Delay(150);
        try
        {
            using var live = ScreenCapture.CaptureRect(global);
            var image = AnnotationRenderer.Composite(live, sel, annotations, scale, sourceIsCropped: true);
            Deliver(image);
        }
        catch (Exception ex)
        {
            Log($"timed capture failed: {ex}");
            Sounds.Beep();
        }
        finally
        {
            _captureInProgress = false;
        }
    }

    private void EndCountdown(bool restore)
    {
        if (!_countdownActive) return;
        _countdownCts?.Cancel();
        _countdownCts = null;
        _countdownActive = false;
        _hotkeys?.UnregisterEscape();
        CloseCountdownWindows();

        if (restore && _forms.Count > 0)
        {
            foreach (var f in _forms)
            {
                f.Cloak();
                f.Show();
                f.PlaceOnScreen();
                f.Reveal();
            }
            var src = _countdownSource ?? _forms[0];
            src.RestoreToolbarAfterCountdown();
            src.ActivateOverlay();
            BumpAutoKill();
        }
        _countdownSource = null;
    }

    private void CloseCountdownWindows()
    {
        foreach (var w in _countdownWindows)
        {
            w.Hide();
            w.Dispose();
        }
        _countdownWindows = new();
    }

    // ------------------------------------------------------------------ logging

    private static readonly string LogPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ScreenShot", "screenshot.log");

    public static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            var fi = new FileInfo(LogPath);
            if (fi.Exists && fi.Length > 512 * 1024) fi.Delete();
            File.AppendAllText(LogPath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {message}{Environment.NewLine}");
        }
        catch { }
    }
}

internal static class ClipboardHelper
{
    /// <summary>Puts PNG (keeps alpha, preferred by modern apps) and a DIB on the clipboard.</summary>
    public static void SetImage(Bitmap image)
    {
        var data = new DataObject();
        var png = new MemoryStream();
        image.Save(png, ImageFormat.Png);
        png.Position = 0;
        data.SetData("PNG", false, png);
        data.SetImage(image);
        Clipboard.SetDataObject(data, true, 10, 100);
    }

    public static void SetText(string text)
    {
        var data = new DataObject();
        data.SetText(text, TextDataFormat.UnicodeText);
        Clipboard.SetDataObject(data, true, 10, 100);
    }

    public static void SetImageFromFile(string path)
    {
        using var bmp = CapturesStore.LoadUnlocked(path);
        if (bmp == null) throw new IOException("Couldn't read image");
        var data = new DataObject();
        var png = new MemoryStream();
        bmp.Save(png, ImageFormat.Png);
        png.Position = 0;
        data.SetData("PNG", false, png);
        data.SetImage(bmp);
        data.SetFileDropList(new System.Collections.Specialized.StringCollection { path });
        Clipboard.SetDataObject(data, true, 10, 100);
    }
}

internal static class Shell
{
    public static void Open(string path)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            OverlayController.Log($"open failed: {ex.Message}");
        }
    }

    public static void RevealInExplorer(string path)
    {
        try
        {
            System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{path}\"");
        }
        catch (Exception ex)
        {
            OverlayController.Log($"reveal failed: {ex.Message}");
        }
    }
}
