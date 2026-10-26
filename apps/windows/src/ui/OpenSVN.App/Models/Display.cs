using System.Globalization;

namespace OpenSVN.App.Models;

public static class Display
{
    public static string FormatDate(string? iso)
    {
        if (string.IsNullOrWhiteSpace(iso)) return "—";
        if (DateTimeOffset.TryParse(iso, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
        {
            return parsed.ToLocalTime().ToString("yyyy-MM-dd HH:mm");
        }
        return iso;
    }

    public static int CategoryOrder(string category) => category switch
    {
        "conflicted" => 0,
        "modified" => 1,
        "added" => 2,
        "deleted" => 3,
        "unversioned" => 4,
        "ignored" => 5,
        "normal" => 6,
        _ => 7,
    };

    public static string CategoryTitle(string category) => category switch
    {
        "conflicted" => "冲突",
        "modified" => "已修改",
        "added" => "已新增",
        "deleted" => "已删除",
        "unversioned" => "未纳入版本控制",
        "ignored" => "已忽略",
        "normal" => "无改动",
        _ => "其他",
    };

    public static string ItemLabel(string item) => item switch
    {
        "added" => "新增",
        "conflicted" => "冲突",
        "deleted" => "删除",
        "external" => "外部",
        "ignored" => "忽略",
        "incomplete" => "不完整",
        "invalid" => "无效",
        "merged" => "合并",
        "missing" => "缺失",
        "modified" => "修改",
        "none" => "无",
        "normal" => "正常",
        "obstructed" => "阻碍",
        "replaced" => "替换",
        "unversioned" => "未版本化",
        _ => item,
    };

    public static string Badge(string item, bool conflicted) => conflicted ? "!" : item switch
    {
        "added" => "A",
        "conflicted" => "!",
        "deleted" => "D",
        "external" => "E",
        "ignored" => "I",
        "incomplete" => "I",
        "invalid" => "!",
        "merged" => "M",
        "missing" => "!",
        "modified" => "M",
        "obstructed" => "!",
        "replaced" => "R",
        "unversioned" => "?",
        _ => "•",
    };

    public static string BadgeColor(string category) => category switch
    {
        "conflicted" => "#D64545",
        "modified" => "#D98B2B",
        "added" => "#2E8B57",
        "deleted" => "#B04A42",
        "unversioned" => "#7A7A7A",
        "ignored" => "#A0A0A0",
        "normal" => "#6A7A8C",
        _ => "#7A7A7A",
    };

    public static string ActionLabel(string action) => action switch
    {
        "added" => "新增",
        "deleted" => "删除",
        "modified" => "修改",
        "replaced" => "替换",
        _ => action,
    };

    public static string RevisionLabel(long? revision) =>
        revision is > 0 ? $"r{revision}" : "—";

    public static string LockOwner(RepositoryLockDto? wcLock, RepositoryLockDto? remoteLock) =>
        wcLock?.Owner ?? remoteLock?.Owner ?? "未知用户";
}
