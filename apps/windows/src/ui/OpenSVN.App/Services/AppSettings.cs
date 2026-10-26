using System.Text.Json;

namespace OpenSVN.App.Services;

public sealed class AppSettings
{
    public string? SvnPath { get; set; }
    public int TimeoutSeconds { get; set; } = 300;
    public int MaxConcurrentWrites { get; set; } = 4;
    public bool AutoPreviewUpdate { get; set; } = true;
    public string? LastWorkingCopy { get; set; }
    public List<string> RecentWorkingCopies { get; set; } = new();

    public static string DataDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenSVN");

    public static string SettingsPath => Path.Combine(DataDirectory, "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return new AppSettings();
            var settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            return settings ?? new AppSettings();
        }
        catch
        {
            return new AppSettings();
        }
    }

    public void Save()
    {
        TimeoutSeconds = Math.Clamp(TimeoutSeconds, 5, 3600);
        MaxConcurrentWrites = Math.Clamp(MaxConcurrentWrites, 1, 32);
        RecentWorkingCopies = RecentWorkingCopies
            .Where(path => !string.IsNullOrWhiteSpace(path))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(8)
            .ToList();

        Directory.CreateDirectory(DataDirectory);
        var temporary = SettingsPath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this,
            new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, SettingsPath, true);
    }

    public AppSettings Clone() => new()
    {
        SvnPath = SvnPath,
        TimeoutSeconds = TimeoutSeconds,
        MaxConcurrentWrites = MaxConcurrentWrites,
        AutoPreviewUpdate = AutoPreviewUpdate,
        LastWorkingCopy = LastWorkingCopy,
        RecentWorkingCopies = new List<string>(RecentWorkingCopies),
    };

    public void RememberWorkingCopy(string path)
    {
        LastWorkingCopy = path;
        RecentWorkingCopies.RemoveAll(item => string.Equals(item, path, StringComparison.OrdinalIgnoreCase));
        RecentWorkingCopies.Insert(0, path);
    }
}
