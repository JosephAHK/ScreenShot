using System.Drawing.Imaging;

namespace ScreenShot;

/// <summary>Lists and saves screenshots in Desktop\ScreenShot Captures.</summary>
internal sealed class CapturesStore
{
    public static CapturesStore Shared { get; } = new();

    public event Action? Changed;

    public string FolderPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
        "ScreenShot Captures");

    public IReadOnlyList<string> Items { get; private set; } = Array.Empty<string>();

    private static readonly string[] Extensions = { ".png", ".jpg", ".jpeg" };

    private CapturesStore()
    {
        EnsureFolder();
        Refresh();
    }

    public void EnsureFolder()
    {
        try { Directory.CreateDirectory(FolderPath); } catch { /* reported on save */ }
    }

    public void Refresh()
    {
        EnsureFolder();
        try
        {
            Items = new DirectoryInfo(FolderPath).EnumerateFiles()
                .Where(f => Extensions.Contains(f.Extension.ToLowerInvariant()) &&
                            (f.Attributes & FileAttributes.Hidden) == 0)
                .OrderByDescending(f => f.LastWriteTimeUtc)
                .Select(f => f.FullName)
                .ToList();
        }
        catch
        {
            Items = Array.Empty<string>();
        }
        Changed?.Invoke();
    }

    public string Save(Bitmap bitmap)
    {
        Directory.CreateDirectory(FolderPath);
        var name = $"Screenshot {DateTime.Now:yyyy-MM-dd} at {DateTime.Now:HH.mm.ss}.png";
        var path = Path.Combine(FolderPath, name);
        // Two captures in the same second: don't overwrite.
        for (int i = 2; File.Exists(path); i++)
            path = Path.Combine(FolderPath, Path.GetFileNameWithoutExtension(name) + $" ({i}).png");
        bitmap.Save(path, ImageFormat.Png);
        Refresh();
        return path;
    }

    public void Delete(string path)
    {
        Items = Items.Where(p => !string.Equals(p, path, StringComparison.OrdinalIgnoreCase)).ToList();
        Changed?.Invoke();
        Task.Run(() =>
        {
            try
            {
                Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(path,
                    Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs,
                    Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
            }
            catch
            {
                try { File.Delete(path); } catch { }
            }
        });
    }

    /// <summary>Loads an image without keeping the file locked.</summary>
    public static Bitmap? LoadUnlocked(string path)
    {
        try
        {
            var bytes = File.ReadAllBytes(path);
            using var ms = new MemoryStream(bytes);
            using var img = Image.FromStream(ms);
            return new Bitmap(img);
        }
        catch
        {
            return null;
        }
    }
}
