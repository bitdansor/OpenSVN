using System.Text.Json;

namespace OpenSVN.App.Native;

public sealed class OpenSVNException : Exception
{
    public OpenSVNException(
        string identifier,
        string message,
        string? detail,
        string? svnCode,
        string? severity,
        string? remediation,
        bool authenticationRequired,
        bool cancelled)
        : base(message)
    {
        Identifier = identifier;
        Detail = detail;
        SvnCode = svnCode;
        Severity = severity;
        Remediation = remediation;
        AuthenticationRequired = authenticationRequired;
        Cancelled = cancelled;
    }

    public string Identifier { get; }
    public string? Detail { get; }
    public string? SvnCode { get; }
    public string? Severity { get; }
    public string? Remediation { get; }
    public bool AuthenticationRequired { get; }
    public bool Cancelled { get; }

    internal static OpenSVNException FromJson(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            string Read(string name) =>
                root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
                    ? value.GetString() ?? ""
                    : "";

            return new OpenSVNException(
                Read("identifier"),
                Read("message"),
                NullIfEmpty(Read("detail")),
                NullIfEmpty(Read("svnCode")),
                NullIfEmpty(Read("severity")),
                NullIfEmpty(Read("remediation")),
                root.TryGetProperty("authenticationRequired", out var auth) &&
                auth.ValueKind == JsonValueKind.True,
                root.TryGetProperty("cancelled", out var cancelled) &&
                cancelled.ValueKind == JsonValueKind.True);
        }
        catch (JsonException)
        {
            return new OpenSVNException("SVN-9998", "原生层返回了无法解析的错误",
                json, null, "fatal", null, false, false);
        }
    }

    private static string? NullIfEmpty(string value) => string.IsNullOrWhiteSpace(value) ? null : value;
}
