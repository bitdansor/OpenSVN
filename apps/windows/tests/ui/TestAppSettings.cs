namespace OpenSVN.App.Services;

// Test-only settings so the native bridge checks keep journals out of the real
// per-user OpenSVN data directory.
public sealed class AppSettings
{
    public static string DataDirectory { get; } = Path.Combine(
        Path.GetTempPath(), "opensvn-ui-tests", Environment.ProcessId.ToString());

    public string? SvnPath { get; set; }
    public int TimeoutSeconds { get; set; } = 300;
    public int MaxConcurrentWrites { get; set; } = 4;
}
