using Microsoft.Win32;

namespace ScreenShot;

internal static class LaunchAtLogin
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "ScreenShot";

    private static string ExePath => Environment.ProcessPath ?? Application.ExecutablePath;

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string v &&
                   v.Trim('"').Equals(ExePath, StringComparison.OrdinalIgnoreCase);
        }
        set
        {
            try
            {
                using var key = Registry.CurrentUser.CreateSubKey(RunKey);
                if (value) key.SetValue(ValueName, $"\"{ExePath}\"");
                else key.DeleteValue(ValueName, false);
            }
            catch (Exception ex)
            {
                OverlayController.Log($"launch-at-login toggle failed: {ex.Message}");
            }
        }
    }
}

/// <summary>Tray icon: left-click = recent-captures flyout, right-click = menu.</summary>
internal sealed class TrayApp : ApplicationContext
{
    private readonly NotifyIcon _tray;
    private readonly OverlayController _overlay = new();
    private readonly HotkeyManager _hotkeys;
    private readonly FlyoutForm _flyout;
    private readonly string _hotkeyLabel;

    public TrayApp()
    {
        _hotkeys = new HotkeyManager(() => _overlay.Begin());
        string? hotkeyError = null;
        try { _hotkeys.Register(); }
        catch (Exception ex) { hotkeyError = ex.Message; }
        _overlay.SetHotkeyManager(_hotkeys);
        _hotkeyLabel = _hotkeys.RegisteredNames.Count > 0 ? string.Join(" / ", _hotkeys.RegisteredNames) : "the tray icon";
        OverlayController.Log($"started; hotkeys: {_hotkeyLabel}");

        _flyout = new FlyoutForm(() => _overlay.Begin(), _hotkeyLabel);

        _tray = new NotifyIcon
        {
            Icon = Icons.TrayIcon(SystemInformation.SmallIconSize.Width),
            Text = $"ScreenShot — {_hotkeyLabel} to capture",
            Visible = true,
        };
        _tray.MouseUp += OnTrayMouseUp;

        if (hotkeyError != null)
        {
            _tray.ShowBalloonTip(5000, "ScreenShot", hotkeyError + " Use the tray icon to capture.", ToolTipIcon.Warning);
        }
        else if (Environment.GetCommandLineArgs().Contains("--welcome"))
        {
            _tray.ShowBalloonTip(4000, "ScreenShot is running", $"Press {_hotkeyLabel} to capture a region.", ToolTipIcon.None);
        }
    }

    private void OnTrayMouseUp(object? sender, MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left)
        {
            if (_flyout.Visible) _flyout.Hide();
            else _flyout.ShowNearTray();
        }
        else if (e.Button == MouseButtons.Right)
        {
            ShowMenu();
        }
    }

    private void ShowMenu()
    {
        _flyout.Hide();
        var menu = new ContextMenuStrip { ShowImageMargin = false };
        menu.Items.Add($"Capture Region\t{_hotkeyLabel}", null, (_, _) => _overlay.Begin());
        menu.Items.Add("Open Captures Folder", null, (_, _) => Shell.Open(CapturesStore.Shared.FolderPath));
        menu.Items.Add(new ToolStripSeparator());
        var launch = new ToolStripMenuItem("Launch at Login") { Checked = LaunchAtLogin.IsEnabled, CheckOnClick = true };
        launch.Click += (_, _) => LaunchAtLogin.IsEnabled = launch.Checked;
        menu.Items.Add(launch);
        menu.ShowCheckMargin = true;
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit ScreenShot", null, (_, _) => ExitThread());
        menu.Closed += (_, _) => BeginInvokeDispose(menu);

        // NotifyIcon menus need the owner to be foreground or they won't close on click-away.
        Native.SetForegroundWindow(_flyout.Handle);
        menu.Show(Cursor.Position);
        menu.Focus();
    }

    private static void BeginInvokeDispose(ContextMenuStrip menu)
    {
        var t = new System.Windows.Forms.Timer { Interval = 200 };
        t.Tick += (_, _) => { t.Dispose(); menu.Dispose(); };
        t.Start();
    }

    protected override void ExitThreadCore()
    {
        _overlay.Dismiss();
        _tray.Visible = false;
        _tray.Dispose();
        _hotkeys.Dispose();
        _flyout.Dispose();
        base.ExitThreadCore();
    }
}
