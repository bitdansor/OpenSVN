namespace OpenSVN.App.Models;

public sealed class StatusItem
{
    public StatusItem(StatusEntryDto entry, string workingCopyRoot)
    {
        Entry = entry;
        DisplayPath = MakeRelative(entry.Path, workingCopyRoot);
    }

    public StatusEntryDto Entry { get; }
    public string Path => Entry.Path;
    public string DisplayPath { get; }
    public string Category => Entry.Category;
    public string CategoryTitle => Display.CategoryTitle(Category);
    public string ItemLabel
    {
        get
        {
            if (Entry.Properties != "modified") return Display.ItemLabel(Entry.Item);
            return Entry.Item is "normal" or "none"
                ? "属性"
                : Display.ItemLabel(Entry.Item) + " · 属性";
        }
    }
    public string Badge => Display.Badge(Entry.Item, IsConflicted);
    public string BadgeColor => Display.BadgeColor(Category);
    public string RevisionDisplay => Display.RevisionLabel(Entry.Revision);

    public bool IsConflicted => Entry.Conflicts.Count > 0 || Entry.Item == "conflicted" ||
                                Entry.Item == "incomplete";
    public bool IsUnversioned => Entry.Item == "unversioned";
    public bool IsIgnored => Entry.Item == "ignored";
    public bool IsMissing => Entry.Item == "missing";
    public bool HasConflictFlags => Entry.Conflicts.Count > 0;
    public string ConflictText => Entry.Conflicts.Count == 0
        ? ""
        : "冲突: " + string.Join(", ", Entry.Conflicts.Select(code => code switch
        {
            "text" => "文本",
            "property" => "属性",
            "tree" => "树",
            _ => code,
        }));

    public bool HasLock => Entry.RepositoryLock is not null || Entry.RemoteLock is not null;
    public bool IsMineLocked => Entry.RepositoryLock is not null;
    public bool IsForeignLocked => Entry.RepositoryLock is null && Entry.RemoteLock is not null;
    public string LockColor => IsMineLocked ? "#D98B2B" : "#D64545";
    public string LockTooltip => IsMineLocked
        ? "本工作副本持有仓库锁" + OwnerSuffix(Entry.RepositoryLock ?? Entry.RemoteLock)
        : "他人持有仓库锁" + OwnerSuffix(Entry.RemoteLock);

    public bool IsCommittable =>
        !IsConflicted &&
        (Entry.Item is "added" or "deleted" or "modified" or "replaced" ||
         Entry.Properties == "modified");

    public bool CanRevert =>
        Entry.Item is "added" or "deleted" or "modified" or "missing" or "conflicted" or "replaced" ||
        Entry.Properties == "modified";

    public bool CanAdd => Entry.Item == "unversioned";
    public bool CanDelete => !IsUnversioned && !IsIgnored && Entry.Item is not "none" and not "deleted";

    public bool IsInteresting =>
        Entry.Item is not "normal" and not "none" ||
        Entry.Properties != "none" ||
        HasLock ||
        Entry.IsWorkingCopyLocked;

    private static string OwnerSuffix(RepositoryLockDto? repositoryLock) =>
        string.IsNullOrWhiteSpace(repositoryLock?.Owner) ? "" : $"（{repositoryLock!.Owner}）";

    private static string MakeRelative(string path, string workingCopyRoot)
    {
        try
        {
            var full = System.IO.Path.IsPathRooted(path)
                ? path
                : System.IO.Path.GetFullPath(System.IO.Path.Combine(workingCopyRoot, path));
            var relative = System.IO.Path.GetRelativePath(workingCopyRoot, full);
            if (relative == ".") relative = System.IO.Path.GetFileName(full.TrimEnd('\\', '/'));
            return relative == "." ? path : relative;
        }
        catch
        {
            return path;
        }
    }
}

public sealed class StatusGroup : List<StatusItem>
{
    public StatusGroup(string key, IEnumerable<StatusItem> items) : base(items)
    {
        Key = key;
    }

    public string Key { get; }
    public string Title => Display.CategoryTitle(Key);
    public string CountText => $"{Count} 项";
}
