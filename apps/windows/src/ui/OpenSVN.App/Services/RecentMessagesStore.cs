using System.Text.Json;

namespace OpenSVN.App.Services;

/// <summary>Successful commit messages only; this is a shared history, not a draft store.</summary>
public sealed class RecentMessagesStore
{
    private const int Maximum = 10;
    private readonly string _path = Path.Combine(AppSettings.DataDirectory, "recent-messages.json");
    private readonly List<string> _messages;

    public RecentMessagesStore()
    {
        try
        {
            _messages = File.Exists(_path)
                ? JsonSerializer.Deserialize<List<string>>(File.ReadAllText(_path)) ?? new()
                : new List<string>();
        }
        catch
        {
            _messages = new List<string>();
        }
    }

    public IReadOnlyList<string> Messages => _messages;

    public void Add(string message)
    {
        message = message.Trim();
        if (message.Length == 0) return;
        _messages.RemoveAll(existing => string.Equals(existing, message, StringComparison.Ordinal));
        _messages.Insert(0, message);
        if (_messages.Count > Maximum) _messages.RemoveRange(Maximum, _messages.Count - Maximum);
        try
        {
            Directory.CreateDirectory(AppSettings.DataDirectory);
            File.WriteAllText(_path, JsonSerializer.Serialize(_messages,
                new JsonSerializerOptions { WriteIndented = true }));
        }
        catch
        {
            // Losing history must never fail a successful commit.
        }
    }
}
