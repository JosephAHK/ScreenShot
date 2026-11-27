namespace ScreenShot;

/// <summary>
/// Global hotkeys via RegisterHotKey (no keyboard hook, no admin).
/// Capture: F4, Ctrl+P (overrides Print in every app, by request) and Print Screen (optional — Windows may own it).
/// Esc is registered only while a timed-capture countdown is running.
/// </summary>
internal sealed class HotkeyManager : NativeWindow, IDisposable
{
    private const int IdF4 = 1;
    private const int IdPrintScreen = 2;
    private const int IdEscape = 3;
    private const int IdCtrlP = 4;

    private readonly Action _onCapture;
    private Action? _onEscape;

    public List<string> RegisteredNames { get; } = new();

    public HotkeyManager(Action onCapture)
    {
        _onCapture = onCapture;
        CreateHandle(new CreateParams());
    }

    public void Register()
    {
        if (Native.RegisterHotKey(Handle, IdF4, Native.MOD_NOREPEAT, (uint)Keys.F4))
            RegisteredNames.Add("F4");
        if (Native.RegisterHotKey(Handle, IdCtrlP, Native.MOD_CONTROL | Native.MOD_NOREPEAT, (uint)Keys.P))
            RegisteredNames.Add("Ctrl+P");
        if (Native.RegisterHotKey(Handle, IdPrintScreen, Native.MOD_NOREPEAT, (uint)Keys.PrintScreen))
            RegisteredNames.Add("PrtSc");
        if (RegisteredNames.Count == 0)
            throw new InvalidOperationException("Could not register F4, Ctrl+P or Print Screen — another app already owns them.");
    }

    public void RegisterEscape(Action onEscape)
    {
        if (_onEscape != null) return;
        if (Native.RegisterHotKey(Handle, IdEscape, Native.MOD_NOREPEAT, (uint)Keys.Escape))
            _onEscape = onEscape;
    }

    public void UnregisterEscape()
    {
        if (_onEscape == null) return;
        Native.UnregisterHotKey(Handle, IdEscape);
        _onEscape = null;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == Native.WM_HOTKEY)
        {
            int id = m.WParam.ToInt32();
            OverlayController.Log($"hotkey {id}");
            if (id == IdEscape) _onEscape?.Invoke();
            else _onCapture();
            return;
        }
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        Native.UnregisterHotKey(Handle, IdF4);
        Native.UnregisterHotKey(Handle, IdPrintScreen);
        Native.UnregisterHotKey(Handle, IdCtrlP);
        Native.UnregisterHotKey(Handle, IdEscape);
        DestroyHandle();
    }
}
