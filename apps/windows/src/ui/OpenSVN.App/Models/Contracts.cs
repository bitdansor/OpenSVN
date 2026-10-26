using System.Text.Json.Serialization;

namespace OpenSVN.App.Models;

public sealed class InstallationDto
{
    public string Executable { get; set; } = "";
    public string Version { get; set; } = "";
    public string Source { get; set; } = "";
}

public sealed class RepositoryLockDto
{
    public string? Token { get; set; }
    public string? Owner { get; set; }
    public string? Comment { get; set; }

    [JsonPropertyName("createdAt")]
    public string? CreatedAt { get; set; }
}

public sealed class CommitInfoDto
{
    public long Revision { get; set; }
    public string? Author { get; set; }
    public string? Date { get; set; }
}

public sealed class StatusEntryDto
{
    public string Path { get; set; } = "";
    public string Item { get; set; } = "normal";
    public string Properties { get; set; } = "none";
    public long? Revision { get; set; }

    [JsonPropertyName("isCopied")]
    public bool IsCopied { get; set; }

    public List<string> Conflicts { get; set; } = new();

    public RepositoryLockDto? RepositoryLock { get; set; }
    public RepositoryLockDto? RemoteLock { get; set; }
    public string? RemoteItem { get; set; }
    public string? RemoteProperties { get; set; }

    [JsonPropertyName("isWorkingCopyLocked")]
    public bool IsWorkingCopyLocked { get; set; }

    public string? Changelist { get; set; }
    public CommitInfoDto? Commit { get; set; }
    public string? Depth { get; set; }
    public string Category { get; set; } = "other";
}

public sealed class StatusSnapshotDto
{
    public string? Target { get; set; }
    public List<StatusEntryDto> Entries { get; set; } = new();
    public long? WorkingCopyRevision { get; set; }
    public long? ServerRevision { get; set; }
}

public sealed class ChangedPathDto
{
    public string Path { get; set; } = "";
    public string Action { get; set; } = "modified";
    public string? Kind { get; set; }
    public string? CopyFromPath { get; set; }
    public long? CopyFromRevision { get; set; }

    public string ActionDisplay => Display.ActionLabel(Action);
    public string CopyDisplay => string.IsNullOrWhiteSpace(CopyFromPath)
        ? ""
        : $"（来自 {CopyFromPath}@{CopyFromRevision}）";
    public string DisplayText => Path + CopyDisplay;
}

public sealed class LogEntryDto
{
    public long Revision { get; set; }
    public string? Author { get; set; }
    public string? Date { get; set; }
    public string Message { get; set; } = "";
    public List<ChangedPathDto> ChangedPaths { get; set; } = new();

    public string RevisionText => "r" + Revision;
    public string AuthorDisplay => string.IsNullOrWhiteSpace(Author) ? "（无作者）" : Author!;
    public string DateDisplay => Display.FormatDate(Date);
    public string MessageFirstLine =>
        Message.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim() ?? "（无提交说明）";
    public string MetaDisplay => $"{AuthorDisplay} · {DateDisplay}";
}

public sealed class LogResponseDto
{
    public List<LogEntryDto> Entries { get; set; } = new();
    public string? Target { get; set; }
    public int Limit { get; set; }
    public bool HasMore { get; set; }
}

public sealed class RepositoryInfoDto
{
    public string Path { get; set; } = "";
    public string Url { get; set; } = "";
    public string? RepositoryRoot { get; set; }
    public string? RepositoryUuid { get; set; }
    public long? Revision { get; set; }
    public string Kind { get; set; } = "none";
    public string? Schedule { get; set; }
    public string? Depth { get; set; }
    public string? WorkingCopyRoot { get; set; }
    public long? LastChangedRevision { get; set; }
    public string? LastChangedAuthor { get; set; }
    public string? LastChangedDate { get; set; }
    public RepositoryLockDto? RepositoryLock { get; set; }
    public string? ConflictOperation { get; set; }
    public string? ConflictType { get; set; }
}

public sealed class InfoReportDto
{
    public List<RepositoryInfoDto> Entries { get; set; } = new();
}

public sealed class SVNPropertyDto
{
    public string Name { get; set; } = "";
    public string Value { get; set; } = "";
}

public sealed class PropertyTargetDto
{
    public string Path { get; set; } = "";
    public List<SVNPropertyDto> Properties { get; set; } = new();
}

public sealed class RemoteChangeDto
{
    public string Path { get; set; } = "";
    public string Item { get; set; } = "normal";
    public string Properties { get; set; } = "none";
    public string LocalItem { get; set; } = "normal";
    public string LocalProperties { get; set; } = "none";
    public bool ConflictsWithLocal { get; set; }

    public string ItemDisplay => Display.ItemLabel(Item) +
                                 (Properties == "modified" ? "（属性）" : "");
    public string LocalDisplay => LocalItem != "normal" || LocalProperties != "none"
        ? "本地已有修改"
        : "";
    public string RiskText => ConflictsWithLocal ? "可能冲突" : "";
}

public sealed class RemotePreviewDto
{
    public List<RemoteChangeDto> Changes { get; set; } = new();
    public RemoteChangeDto? RootPropertyChange { get; set; }
    public long? WorkingCopyRevision { get; set; }
    public long? ServerRevision { get; set; }
}

public sealed class OperationPreviewDto
{
    public string Summary { get; set; } = "";
    public string Detail { get; set; } = "";
    public string Risk { get; set; } = "low";
    public List<string> AffectedPaths { get; set; } = new();
    public List<string> DiscardedPaths { get; set; } = new();
}

public sealed class UpdateSummaryDto
{
    public string Target { get; set; } = "";
    public long? FromRevision { get; set; }
    public long? ToRevision { get; set; }
    public List<string> UpdatedPaths { get; set; } = new();
    public List<string> ConflictedPaths { get; set; } = new();
    public List<string> RemovedPaths { get; set; } = new();
}

public sealed class CommitSummaryDto
{
    public long? Revision { get; set; }
    public List<string> CommittedPaths { get; set; } = new();
}

public sealed class DiffDto
{
    public string Text { get; set; } = "";
    public bool IsTruncated { get; set; }
    public long ByteCount { get; set; }
}

public sealed class LockEntryDto
{
    public string Path { get; set; } = "";
    public string? Token { get; set; }
    public string? Owner { get; set; }
    public string? Comment { get; set; }
    public string? CreatedAt { get; set; }
    public bool IsMine { get; set; }
}

public sealed class LockListDto
{
    public List<LockEntryDto> Locks { get; set; } = new();
}

public sealed class LockOutcomeDto
{
    public List<string> LockedPaths { get; set; } = new();
    public string? Owner { get; set; }
}

public sealed class UnlockOutcomeDto
{
    public List<string> UnlockedPaths { get; set; } = new();
}

public sealed class ConflictBackupDto
{
    public string Directory { get; set; } = "";
    public List<string> Files { get; set; } = new();
}

public sealed class ConflictScanDto
{
    public string Path { get; set; } = "";
    public List<long> MarkerLines { get; set; } = new();
    public bool Skipped { get; set; }
    public string SkipReason { get; set; } = "";
}

public sealed class ResolveOutcomeDto
{
    public List<string> ResolvedPaths { get; set; } = new();
    public ConflictBackupDto? Backup { get; set; }
    public List<ConflictScanDto> Scans { get; set; } = new();
    public List<string> ResidualMarkers { get; set; } = new();
}

public sealed class ConflictArtifactsDto
{
    public string Path { get; set; } = "";
    public string Operation { get; set; } = "";
    public string Type { get; set; } = "";
    public string? PrevBaseFile { get; set; }
    public string? PrevWorkingCopyFile { get; set; }
    public string? CurrentBaseFile { get; set; }
    public string? SourceLeftPath { get; set; }
    public string? SourceRightPath { get; set; }
    public long? SourceLeftRevision { get; set; }
    public long? SourceRightRevision { get; set; }
}

public sealed class CredentialScopeDto
{
    public string Host { get; set; } = "";
    public string? Realm { get; set; }
    public string StorageKey { get; set; } = "";

    public string DisplayName => string.IsNullOrWhiteSpace(Realm) ? Host : $"{Host} · {Realm}";
}

public sealed class CredentialScopesDto
{
    public List<CredentialScopeDto> Scopes { get; set; } = new();
}

public sealed class JournalEntryDto
{
    public string Id { get; set; } = "";
    public string Kind { get; set; } = "";
    public string Title { get; set; } = "";
    public string WorkingCopy { get; set; } = "";
    public string Summary { get; set; } = "";
    public string StartedAt { get; set; } = "";
    public string RecoveryAdvice { get; set; } = "";

    public string MetaDisplay => $"{WorkingCopy} · {StartedAt}";
}

public sealed class JournalDto
{
    public List<JournalEntryDto> Entries { get; set; } = new();
    public string? Quarantined { get; set; }
    public string? WriteFailure { get; set; }
}

public sealed class IgnoreOutcomeDto
{
    public List<string> Added { get; set; } = new();
    public List<string> Already { get; set; } = new();
}
