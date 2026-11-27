namespace ScreenShot;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        // Build helper: `ScreenShot.exe --make-icon path\AppIcon.ico`
        if (args.Length == 2 && args[0] == "--make-icon")
        {
            Icons.WriteIco(args[1]);
            return 0;
        }

        using var mutex = new Mutex(true, @"Local\ScreenShot.SingleInstance", out bool first);
        if (!first) return 0;

        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) => OverlayController.Log($"unhandled: {e.Exception}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => OverlayController.Log($"fatal: {e.ExceptionObject}");

        Application.Run(new TrayApp());
        return 0;
    }
}
