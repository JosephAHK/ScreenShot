using System.Media;

namespace ScreenShot;

internal static class Sounds
{
    private static readonly string MediaDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Media");

    private static readonly Dictionary<string, SoundPlayer> Cache = new();

    private static void Play(string file, SystemSound fallback)
    {
        try
        {
            if (!Cache.TryGetValue(file, out var player))
            {
                var path = Path.Combine(MediaDir, file);
                if (!File.Exists(path)) { fallback.Play(); return; }
                player = new SoundPlayer(path);
                player.Load();
                Cache[file] = player;
            }
            player.Play();
        }
        catch
        {
            fallback.Play();
        }
    }

    public static void Captured() => Play("Windows Notify System Generic.wav", SystemSounds.Asterisk);
    public static void Tink() => Play("Windows Navigation Start.wav", SystemSounds.Asterisk);
    public static void Trash() => Play("Windows Recycle.wav", SystemSounds.Asterisk);
    public static void Beep() => SystemSounds.Beep.Play();
}
