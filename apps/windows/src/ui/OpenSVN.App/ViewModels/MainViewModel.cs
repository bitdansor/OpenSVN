using OpenSVN.App.Models;
using OpenSVN.App.Native;
using OpenSVN.App.Services;
using System.Collections.ObjectModel;

namespace OpenSVN.App.ViewModels;

public enum NotificationSeverity
{
    Info,
    Success,
    Warning,
    Error,
}

public enum ConnectionState
{
    Unknown,
    Reachable,
    AuthenticationRequired,
    Unreachable,
}

public sealed class RecentWorkingCopyItem
{
    public required string Path { get; init; }
    public required string DisplayName { get; init; }
    public required bool IsAvailable { get; init; }
    public string StatusText => IsAvailable ? "可用" : "目录不存在，点击可重新定位";
}

public sealed class UpdatePreviewAttempt
{
    public RemotePreviewDto? Preview { get; init; }
    public OpenSVNException? Error { get; init; }
    public required string WorkingCopy { get; init; }
    public required long Session { get; init; }
}

public sealed class MainViewModel : ObservableObject, IDisposable
{
    private readonly SemaphoreSlim _refreshGate = new(1, 1);
    private readonly WorkingCopyWatcher _watcher;
    private OpenSVNClient? _client;
    private AppSettings _settings;
    private string? _workingCopyPath;
    private string? _repositoryUrl;
    private string? _repositoryHost;
    private string? _workingCopyRevisionText;
    private InstallationDto? _installation;
    private string? _initializationError;
    private string? _statusError;
    private bool _isInitializing;
    private bool _hasConflicts;
    private int _changedCount;
    private ConnectionState _connectionState = ConnectionState.Unknown;
    private JournalDto? _journal;
    private List<StatusItem> _selectedItems = new();
    private long? _lastCommitRevision;
    private long _sessionVersion;

    public MainViewModel()
    {
        _settings = AppSettings.Load();
        Tasks.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(TaskCenter.IsBusy))
            {
                OnPropertyChanged(nameof(IsBusy));
                OnPropertyChanged(nameof(IsIdle));
            }
            if (args.PropertyName == nameof(TaskCenter.CurrentDetail))
            {
                OnPropertyChanged(nameof(CurrentTaskDetail));
            }
        };
        _watcher = new WorkingCopyWatcher(AutoRefreshAsync);
        RefreshRecentWorkingCopies();
    }

    public AppSettings Settings => _settings;
    public TaskCenter Tasks { get; } = new();
    public RecentMessagesStore RecentMessages { get; } = new();
    public ObservableCollection<StatusItem> StatusItems { get; } = new();
    public ObservableCollection<StatusGroup> StatusGroups { get; } = new();
    public ObservableCollection<RecentWorkingCopyItem> RecentWorkingCopies { get; } = new();
    public bool HasRecentWorkingCopies => RecentWorkingCopies.Count > 0;

    public bool IsBusy => Tasks.IsBusy;
    public bool IsIdle => !Tasks.IsBusy;
    public bool HasSvn => _client is not null;
    public string CurrentTaskDetail => Tasks.CurrentDetail;
    public InstallationDto? Installation
    {
        get => _installation;
        private set
        {
            if (SetProperty(ref _installation, value)) OnPropertyChanged(nameof(InstallationSummary));
        }
    }

    public string InstallationSummary => _installation is null
        ? "未找到 svn"
        : $"svn {_installation.Version} · {_installation.Executable}";

    public bool IsInitializing
    {
        get => _isInitializing;
        private set => SetProperty(ref _isInitializing, value);
    }

    public string? InitializationError
    {
        get => _initializationError;
        private set
        {
            if (SetProperty(ref _initializationError, value)) OnPropertyChanged(nameof(HasInitializationError));
        }
    }

    public bool HasInitializationError => !string.IsNullOrWhiteSpace(InitializationError);

    public string? StatusError
    {
        get => _statusError;
        private set
        {
            if (!SetProperty(ref _statusError, value)) return;
            OnPropertyChanged(nameof(HasStatusError));
            OnPropertyChanged(nameof(StatusSummary));
            StatusChanged?.Invoke();
        }
    }

    public bool HasStatusError => !string.IsNullOrWhiteSpace(StatusError);
    public bool HasWorkingCopy => !string.IsNullOrWhiteSpace(_workingCopyPath);
    public bool HasNoWorkingCopy => !HasWorkingCopy;
    public string WorkingCopyPath => _workingCopyPath ?? "";
    public string WorkingCopyName => string.IsNullOrWhiteSpace(_workingCopyPath)
        ? "未打开工作副本"
        : new DirectoryInfo(_workingCopyPath).Name;
    public string WorkingCopyRevisionText => _workingCopyRevisionText ?? "";
    public string RepositoryUrl => _repositoryUrl ?? "";
    public string RepositoryHost => _repositoryHost ?? "该仓库";
    public string PropertiesTarget { get; set; } = "";

    public ConnectionState Connection
    {
        get => _connectionState;
        private set
        {
            if (!SetProperty(ref _connectionState, value)) return;
            OnPropertyChanged(nameof(ConnectionText));
            OnPropertyChanged(nameof(ConnectionColor));
            OnPropertyChanged(nameof(ConnectionTooltip));
        }
    }

    public string ConnectionText => _connectionState switch
    {
        ConnectionState.Reachable => "服务器可达",
        ConnectionState.AuthenticationRequired => "需要认证",
        ConnectionState.Unreachable => "服务器不可达",
        _ => "尚未联网",
    };

    public string ConnectionColor => _connectionState switch
    {
        ConnectionState.Reachable => "#2E8B57",
        ConnectionState.AuthenticationRequired => "#D98B2B",
        ConnectionState.Unreachable => "#D64545",
        _ => "#8A8A8A",
    };

    public string ConnectionTooltip => _connectionState switch
    {
        ConnectionState.Reachable => "最近一次联网操作成功。",
        ConnectionState.AuthenticationRequired => "最近一次联网操作需要登录；这与网络故障的处理方式不同。",
        ConnectionState.Unreachable => "最近一次联网操作无法连接服务器。",
        _ => "本地读取不算作服务器可达的证据。",
    };

    public bool HasConflicts
    {
        get => _hasConflicts;
        private set => SetProperty(ref _hasConflicts, value);
    }

    public int ChangedCount
    {
        get => _changedCount;
        private set => SetProperty(ref _changedCount, value);
    }

    public string StatusSummary
    {
        get
        {
            if (!HasWorkingCopy) return "未打开工作副本";
            if (ChangedCount == 0) return HasStatusError ? "状态未知" : "工作副本干净";
            var counts = StatusItems
                .GroupBy(item => item.Category)
                .OrderBy(group => Display.CategoryOrder(group.Key))
                .Select(group => $"{group.Count()} 个{Display.CategoryTitle(group.Key)}");
            var summary = string.Join(" · ", counts);
            return HasStatusError ? summary + " · 状态可能已过期" : summary;
        }
    }

    public IReadOnlyList<StatusItem> SelectedItems => _selectedItems;
    public string SelectionText => _selectedItems.Count == 0 ? "未选择路径" : $"已选择 {_selectedItems.Count} 项";
    public IReadOnlyList<StatusItem> CommittableItems =>
        StatusItems.Where(item => item.IsCommittable).ToList();

    public JournalDto? Journal
    {
        get => _journal;
        private set
        {
            if (SetProperty(ref _journal, value)) OnPropertyChanged(nameof(HasJournalWarning));
        }
    }

    public bool HasJournalWarning =>
        _journal is not null &&
        (_journal.Entries.Count > 0 || !string.IsNullOrWhiteSpace(_journal.Quarantined) ||
         !string.IsNullOrWhiteSpace(_journal.WriteFailure));

    public long? LastCommitRevision
    {
        get => _lastCommitRevision;
        private set => SetProperty(ref _lastCommitRevision, value);
    }

    public event Action? StatusChanged;
    public event Action? WorkingCopyChanged;
    public event Action? SettingsChanged;
    public event Action<JournalDto>? JournalAvailable;
    public event Action<NotificationSeverity, string, string>? Notification;
    public event Func<string, Task<SVNCredential?>>? CredentialRequested;

    public async Task InitializeAsync()
    {
        if (_client is not null) return;
        IsInitializing = true;
        try
        {
            var (client, installation) = await CreateClientAsync(_settings);
            _client = client;
            Installation = installation;
            OnPropertyChanged(nameof(HasSvn));
            await RefreshJournalAsync();
            var last = _settings.LastWorkingCopy;
            if (!string.IsNullOrWhiteSpace(last) && Directory.Exists(last))
            {
                try
                {
                    await OpenWorkingCopyAsync(last, remember: false);
                }
                catch (Exception exception)
                {
                    Notify(NotificationSeverity.Warning, "无法重新打开上次的工作副本", exception.Message);
                }
            }
        }
        catch (Exception exception) when (exception is OpenSVNException or InvalidOperationException)
        {
            InitializationError = exception is OpenSVNException openSvn
                ? $"{openSvn.Identifier} {openSvn.Message}"
                : exception.Message;
            Notify(NotificationSeverity.Error, "无法启动 SVN 服务",
                InitializationError + (exception is OpenSVNException e && !string.IsNullOrWhiteSpace(e.Remediation)
                    ? "\n" + e.Remediation
                    : ""));
        }
        catch (Exception exception)
        {
            InitializationError = exception.Message;
            Notify(NotificationSeverity.Error, "无法启动 SVN 服务", exception.Message);
        }
        finally
        {
            IsInitializing = false;
            RaiseState();
        }
    }

    private static async Task<(OpenSVNClient Client, InstallationDto Installation)> CreateClientAsync(AppSettings settings)
    {
        var client = await OpenSVNClient.CreateAsync(settings);
        try
        {
            var installation = await client.GetInstallationAsync();
            return (client, installation);
        }
        catch
        {
            client.Dispose();
            throw;
        }
    }

    public async Task<bool> OpenWorkingCopyAsync(string path, bool remember = true)
    {
        if (Tasks.IsBusy)
        {
            Notify(NotificationSeverity.Warning, "操作进行中", "请等待当前操作结束或取消它。");
            return false;
        }
        if (_client is null)
        {
            Notify(NotificationSeverity.Error, "SVN 服务不可用", "请先在设置中指定 svn 可执行文件。");
            return false;
        }

        var root = FindWorkingCopyRoot(path);
        if (root is null)
        {
            Notify(NotificationSeverity.Error, "不是工作副本",
                "所选目录及其上级都没有 .svn 目录。请选择工作副本，或使用「检出仓库」。");
            return false;
        }

        _workingCopyPath = root;
        PropertiesTarget = root;
        _repositoryUrl = null;
        _repositoryHost = null;
        _sessionVersion++;
        StatusError = null;
        Connection = ConnectionState.Unknown;
        SetSelection(Array.Empty<StatusItem>());
        _watcher.Watch(root);
        if (remember)
        {
            _settings.RememberWorkingCopy(root);
            PersistSettings("最近工作副本未能保存。");
            RefreshRecentWorkingCopies();
        }

        OnPropertyChanged(nameof(HasWorkingCopy));
        OnPropertyChanged(nameof(HasNoWorkingCopy));
        OnPropertyChanged(nameof(WorkingCopyPath));
        OnPropertyChanged(nameof(WorkingCopyName));
        WorkingCopyChanged?.Invoke();

        await LoadInfoAsync();
        var refreshed = await RefreshStatusAsync(silent: false);
        await RefreshJournalAsync();
        if (!refreshed)
        {
            Notify(NotificationSeverity.Warning, "已打开工作副本，但读取状态失败",
                "可以稍后刷新；若状态持续失败，请检查工作副本锁或磁盘权限。");
        }
        return true;
    }

    public bool CloseWorkingCopy()
    {
        if (Tasks.IsBusy)
        {
            Notify(NotificationSeverity.Warning, "操作进行中", "请等待当前操作结束或取消它。");
            return false;
        }
        _watcher.Stop();
        _workingCopyPath = null;
        _repositoryUrl = null;
        _repositoryHost = null;
        _workingCopyRevisionText = null;
        PropertiesTarget = "";
        _sessionVersion++;
        StatusError = null;
        StatusItems.Clear();
        StatusGroups.Clear();
        ChangedCount = 0;
        HasConflicts = false;
        SetSelection(Array.Empty<StatusItem>());
        _settings.LastWorkingCopy = null;
        PersistSettings("关闭工作副本后的设置未能保存。");
        Connection = ConnectionState.Unknown;
        OnPropertyChanged(nameof(HasWorkingCopy));
        OnPropertyChanged(nameof(HasNoWorkingCopy));
        OnPropertyChanged(nameof(WorkingCopyPath));
        OnPropertyChanged(nameof(WorkingCopyName));
        OnPropertyChanged(nameof(WorkingCopyRevisionText));
        OnPropertyChanged(nameof(RepositoryUrl));
        OnPropertyChanged(nameof(RepositoryHost));
        OnPropertyChanged(nameof(StatusSummary));
        WorkingCopyChanged?.Invoke();
        return true;
    }

    private static string? FindWorkingCopyRoot(string path)
    {
        try
        {
            var directory = new DirectoryInfo(Path.GetFullPath(path));
            while (directory is not null)
            {
                if (Directory.Exists(Path.Combine(directory.FullName, ".svn"))) return directory.FullName;
                directory = directory.Parent;
            }
        }
        catch
        {
            return null;
        }
        return null;
    }

    public async Task<bool> RefreshStatusAsync(bool silent = false)
    {
        var workingCopy = _workingCopyPath;
        if (_client is null || string.IsNullOrWhiteSpace(workingCopy)) return false;

        // Wait instead of failing: a refresh that started for an older working
        // copy must not make the new one appear unreadable.
        await _refreshGate.WaitAsync();
        try
        {
            var client = _client;
            if (client is null || !SamePath(workingCopy, _workingCopyPath)) return false;
            var snapshot = await client.InvokeAsync<StatusSnapshotDto>("status", new
            {
                path = workingCopy,
                includeIgnored = false,
                checkRepository = false,
            });
            if (!SamePath(workingCopy, _workingCopyPath)) return false;
            StatusError = null;
            ApplyStatus(snapshot);
            return true;
        }
        catch (OpenSVNException exception)
        {
            if (!SamePath(workingCopy, _workingCopyPath)) return false;
            StatusError = exception.Message;
            if (!silent) ReportException(exception);
            return false;
        }
        catch (Exception exception)
        {
            if (!SamePath(workingCopy, _workingCopyPath)) return false;
            StatusError = exception.Message;
            if (!silent) Notify(NotificationSeverity.Error, "刷新失败", exception.Message);
            return false;
        }
        finally
        {
            _refreshGate.Release();
        }
    }

    public async Task<bool> RefreshRemoteStatusAsync()
    {
        var workingCopy = _workingCopyPath;
        if (_client is null || string.IsNullOrWhiteSpace(workingCopy)) return false;
        await _refreshGate.WaitAsync();
        try
        {
            var client = _client;
            if (client is null || !SamePath(workingCopy, _workingCopyPath)) return false;
            var snapshot = await WithAuthAsync(credential => client.InvokeAsync<StatusSnapshotDto>(
                "status", new
                {
                    path = workingCopy,
                    includeIgnored = false,
                    checkRepository = true,
                }, null, CancellationToken.None, credential));
            if (!SamePath(workingCopy, _workingCopyPath)) return false;
            StatusError = null;
            ApplyStatus(snapshot);
            Connection = ConnectionState.Reachable;
            return true;
        }
        catch (OpenSVNException exception)
        {
            if (!SamePath(workingCopy, _workingCopyPath)) return false;
            StatusError = exception.Message;
            UpdateConnection(exception);
            ReportException(exception);
            return false;
        }
        finally
        {
            _refreshGate.Release();
        }
    }

    private void ApplyStatus(StatusSnapshotDto snapshot)
    {
        _workingCopyRevisionText = snapshot.WorkingCopyRevision switch
        {
            > 0 => $"r{snapshot.WorkingCopyRevision}",
            -1 => "混合版本",
            _ => "",
        };

        var items = snapshot.Entries
            .Select(entry => new StatusItem(entry, _workingCopyPath ?? ""))
            .Where(item => item.IsInteresting)
            .OrderBy(item => Display.CategoryOrder(item.Category))
            .ThenBy(item => item.DisplayPath, StringComparer.OrdinalIgnoreCase)
            .ToList();

        StatusItems.Clear();
        foreach (var item in items) StatusItems.Add(item);

        StatusGroups.Clear();
        foreach (var group in items.GroupBy(item => item.Category)
                     .OrderBy(group => Display.CategoryOrder(group.Key)))
        {
            StatusGroups.Add(new StatusGroup(group.Key, group));
        }

        ChangedCount = items.Count;
        HasConflicts = items.Any(item => item.IsConflicted);
        _selectedItems = _selectedItems
            .Select(selected => items.FirstOrDefault(item => item.Path == selected.Path))
            .Where(item => item is not null)
            .Select(item => item!)
            .ToList();

        OnPropertyChanged(nameof(WorkingCopyRevisionText));
        OnPropertyChanged(nameof(StatusSummary));
        OnPropertyChanged(nameof(SelectionText));
        OnPropertyChanged(nameof(CommittableItems));
        StatusChanged?.Invoke();
    }

    private async Task AutoRefreshAsync()
    {
        if (!HasWorkingCopy) return;
        if (Tasks.IsBusy)
        {
            _watcher.RequestRefresh();
            return;
        }
        await RefreshStatusAsync(silent: true);
    }

    public async Task<InfoReportDto?> LoadInfoAsync()
    {
        var workingCopy = _workingCopyPath;
        if (_client is null || string.IsNullOrWhiteSpace(workingCopy)) return null;
        try
        {
            var report = await _client.InvokeAsync<InfoReportDto>("info", new { target = workingCopy });
            if (!SamePath(workingCopy, _workingCopyPath)) return null;
            var primary = report.Entries.FirstOrDefault();
            _repositoryUrl = primary?.Url;
            _repositoryHost = HostFromUrl(primary?.Url) ?? WorkingCopyName;
            OnPropertyChanged(nameof(RepositoryUrl));
            OnPropertyChanged(nameof(RepositoryHost));
            return report;
        }
        catch (OpenSVNException exception)
        {
            if (!SamePath(workingCopy, _workingCopyPath)) return null;
            if (!exception.Cancelled) UpdateConnection(exception);
            return null;
        }
    }

    private static string? HostFromUrl(string? url)
    {
        if (string.IsNullOrWhiteSpace(url)) return null;
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            if (!string.IsNullOrEmpty(uri.Host)) return uri.Host;
            return uri.IsFile ? "本地仓库" : url;
        }
        return url;
    }

    public async Task<LogResponseDto?> LoadLogAsync(int limit = 50, long? endRevision = null)
    {
        if (_client is null || string.IsNullOrWhiteSpace(_workingCopyPath)) return null;
        try
        {
            var page = await WithAuthAsync(credential => _client.InvokeAsync<LogResponseDto>(
                "log", new { target = _workingCopyPath, limit, endRevision }, null,
                CancellationToken.None, credential));
            Connection = ConnectionState.Reachable;
            return page;
        }
        catch (OpenSVNException exception)
        {
            UpdateConnection(exception);
            ReportException(exception);
            return null;
        }
    }

    public async Task<DiffDto?> LoadDiffAsync(string path)
    {
        if (_client is null) return null;
        try
        {
            return await _client.InvokeAsync<DiffDto>("diff_working_copy",
                new { path, contextLines = 3, maxBytes = 4_000_000 });
        }
        catch (OpenSVNException exception)
        {
            ReportException(exception);
            return null;
        }
    }

    public async Task<DiffDto?> LoadRevisionDiffAsync(string path, long revision)
    {
        if (_client is null) return null;
        try
        {
            var diff = await WithAuthAsync(credential => _client.InvokeAsync<DiffDto>(
                "diff_revision", new { path, revision, contextLines = 3, maxBytes = 4_000_000 },
                null, CancellationToken.None, credential));
            Connection = ConnectionState.Reachable;
            return diff;
        }
        catch (OpenSVNException exception)
        {
            UpdateConnection(exception);
            ReportException(exception);
            return null;
        }
    }

    public async Task<List<PropertyTargetDto>?> LoadPropertiesAsync(string path, bool recursive = false)
    {
        if (_client is null) return null;
        try
        {
            return await _client.InvokeAsync<List<PropertyTargetDto>>("properties",
                new { path, recursive });
        }
        catch (OpenSVNException exception)
        {
            ReportException(exception);
            return null;
        }
    }

    public async Task<OperationPreviewDto?> PreviewDeleteAsync(IReadOnlyList<string> paths)
    {
        if (_client is null || paths.Count == 0) return null;
        try
        {
            return await _client.InvokeAsync<OperationPreviewDto>("preview_delete",
                new { paths = paths.ToArray() });
        }
        catch (OpenSVNException exception)
        {
            ReportException(exception);
            return null;
        }
    }

    public async Task<OperationPreviewDto?> PreviewRevertAsync(IReadOnlyList<string> paths)
    {
        if (_client is null || paths.Count == 0) return null;
        try
        {
            return await _client.InvokeAsync<OperationPreviewDto>("preview_revert",
                new { paths = paths.ToArray() });
        }
        catch (OpenSVNException exception)
        {
            ReportException(exception);
            return null;
        }
    }

    public async Task<UpdatePreviewAttempt> PreviewUpdateAsync()
    {
        var workingCopy = _workingCopyPath;
        var client = _client;
        var session = _sessionVersion;
        if (client is null || string.IsNullOrWhiteSpace(workingCopy))
            throw new InvalidOperationException("没有打开工作副本。");

        bool Current() =>
            session == _sessionVersion &&
            ReferenceEquals(client, _client) &&
            SamePath(workingCopy, _workingCopyPath);

        try
        {
            var preview = await WithAuthAsync(
                credential => client.InvokeAsync<RemotePreviewDto>(
                    "remote_preview", new { path = workingCopy }, null,
                    CancellationToken.None, credential),
                allowPrompt: true, stillCurrent: Current);
            if (Current()) Connection = ConnectionState.Reachable;
            return new UpdatePreviewAttempt
            {
                Preview = preview,
                WorkingCopy = workingCopy,
                Session = session,
            };
        }
        catch (OpenSVNException exception)
        {
            if (Current()) UpdateConnection(exception);
            return new UpdatePreviewAttempt
            {
                Error = exception,
                WorkingCopy = workingCopy,
                Session = session,
            };
        }
        catch (Exception) when (!Current())
        {
            return new UpdatePreviewAttempt
            {
                WorkingCopy = workingCopy,
                Session = session,
            };
        }
    }

    public bool IsCurrentWorkingCopy(string path, long session) =>
        session == _sessionVersion && SamePath(path, _workingCopyPath);

    public async Task<bool> UpdateAsync(long? revision = null, string? expectedWorkingCopy = null,
        long? expectedSession = null)
    {
        if (!HasWorkingCopy) return false;
        if (expectedWorkingCopy is not null &&
            ((expectedSession is long session && session != _sessionVersion) ||
             !SamePath(expectedWorkingCopy, _workingCopyPath)))
        {
            Notify(NotificationSeverity.Warning, "工作副本已切换",
                "旧的更新确认已丢弃，请重新发起更新。");
            return false;
        }

        var workingCopy = expectedWorkingCopy ?? _workingCopyPath;
        var client = _client;
        if (client is null || string.IsNullOrWhiteSpace(workingCopy)) return false;
        Func<Task> retry = BoundRetry(workingCopy,
            async () => { await UpdateAsync(revision, workingCopy, expectedSession); });
        var summary = await RunWriteAsync("更新 " + WorkingCopyName,
            (credential, progress, cancellationToken) => client.InvokeAsync<UpdateSummaryDto>(
                "update", new { path = workingCopy, revision }, progress, cancellationToken,
                credential), retry, null, true,
            "工作副本可能处于中间状态，必要时执行 Cleanup。");
        if (summary is null) return false;

        Connection = ConnectionState.Reachable;
        await LoadInfoAsync();
        var revisionText = summary.ToRevision is long target ? $"更新到 r{target}" : "更新完成";
        if (summary.ConflictedPaths.Count > 0)
        {
            Notify(NotificationSeverity.Warning, revisionText + "，但产生了冲突",
                $"有 {summary.ConflictedPaths.Count} 个路径冲突：" +
                string.Join("、", summary.ConflictedPaths.Take(5)) +
                (summary.ConflictedPaths.Count > 5 ? " 等" : "") +
                (summary.ConflictsVerified ? "" : "\n无法读取更新后的状态，冲突列表可能不完整。"));
        }
        else if (!summary.ConflictsVerified)
        {
            Notify(NotificationSeverity.Warning, revisionText + "，但冲突状态未知",
                "更新已完成，但无法读取更新后的工作副本状态。请刷新变更列表确认是否产生冲突。");
        }
        else
        {
            Notify(NotificationSeverity.Success, revisionText,
                $"更新 {summary.UpdatedPaths.Count} 个路径，合并 {summary.MergedPaths.Count} 个，" +
                $"新增 {summary.AddedPaths.Count} 个，删除 {summary.RemovedPaths.Count} 个。");
        }
        return true;
    }

    public async Task<CommitSummaryDto?> CommitAsync(
        IReadOnlyList<string> paths,
        string message,
        SVNCredential? credential = null,
        bool allowAuthPrompt = true)
    {
        if (_client is null || paths.Count == 0) return null;
        var retryRoot = _workingCopyPath;
        Func<Task> retry = BoundRetry(retryRoot,
            async () => { await CommitAsync(paths, message, null, true); });
        CommitSummaryDto? summary;
        try
        {
            summary = await Tasks.RunAsync("提交 " + WorkingCopyName,
                async (progress, cancellationToken) =>
                {
                    return await WithAuthAsync(
                        selected => _client.InvokeAsync<CommitSummaryDto>("commit", new
                        {
                            paths = paths.ToArray(),
                            message,
                        }, progress, cancellationToken, selected ?? credential),
                        allowAuthPrompt);
                }, retry, "已提交");
        }
        catch
        {
            await RefreshJournalAsync();
            throw;
        }

        if (summary is null)
        {
            Notify(NotificationSeverity.Warning, "提交已取消", "提交说明与勾选仍然保留。");
            return null;
        }

        RecentMessages.Add(message);
        LastCommitRevision = summary.Revision;
        await RefreshStatusAsync(silent: true);
        await LoadInfoAsync();
        await RefreshJournalAsync();
        Connection = ConnectionState.Reachable;
        if (summary?.Revision is long revision)
        {
            Notify(NotificationSeverity.Success, $"提交成功 r{revision}", message);
        }
        return summary;
    }

    public async Task<bool> AddAsync(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return false;
        Func<Task> retry = async () => { await AddAsync(paths); };
        var result = await RunWriteAsync("加入版本控制",
            (credential, progress, cancellationToken) => _client!.InvokeAsync<OkDto>("add",
                new { paths = paths.ToArray(), force = false, includeIgnored = false },
                progress, cancellationToken, credential), retry,
            $"已将 {paths.Count} 个路径加入版本控制。");
        return result is not null;
    }

    public async Task<bool> DeleteAsync(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return false;
        Func<Task> retry = async () => { await DeleteAsync(paths); };
        var result = await RunWriteAsync("删除路径",
            (credential, progress, cancellationToken) => _client!.InvokeAsync<OkDto>("delete",
                new { paths = paths.ToArray(), confirmed = true, force = true },
                progress, cancellationToken, credential), retry,
            $"已删除 {paths.Count} 个路径，并纳入下次提交。");
        return result is not null;
    }

    public async Task<bool> RevertAsync(IReadOnlyList<string> paths, bool recursive = true)
    {
        if (paths.Count == 0) return false;
        Func<Task> retry = async () => { await RevertAsync(paths, recursive); };
        var result = await RunWriteAsync("还原本地修改",
            (credential, progress, cancellationToken) => _client!.InvokeAsync<OkDto>("revert",
                new { paths = paths.ToArray(), recursive, confirmed = true },
                progress, cancellationToken, credential), retry,
            $"已还原 {paths.Count} 个路径。未纳入版本控制的文件不受影响。");
        return result is not null;
    }

    public async Task<ResolveOutcomeDto?> ResolveAsync(
        IReadOnlyList<string> paths, string strategy, bool backup = true)
    {
        if (paths.Count == 0) return null;
        Func<Task> retry = async () => { await ResolveAsync(paths, strategy, backup); };
        var outcome = await RunWriteAsync("解决冲突",
            (credential, progress, cancellationToken) => _client!.InvokeAsync<ResolveOutcomeDto>(
                "resolve", new
                {
                    paths = paths.ToArray(),
                    strategy,
                    confirmed = true,
                    backup,
                }, progress, cancellationToken, credential), retry, null);
        return outcome;
    }

    public async Task<bool> LockAsync(IReadOnlyList<string> paths, string? comment, bool steal)
    {
        if (paths.Count == 0) return false;
        Func<Task> retry = async () => { await LockAsync(paths, comment, steal); };
        var result = await RunWriteAsync(steal ? "强制锁定路径" : "锁定路径",
            (credential, progress, cancellationToken) => _client!.InvokeAsync<LockOutcomeDto>("lock",
                new { paths = paths.ToArray(), comment, steal, confirmed = steal },
                progress, cancellationToken, credential), retry,
            steal ? "已抢占锁定。持有者将无法提交，直到发现锁已易主。" : "已取得仓库锁。");
        return result is not null;
    }

    public async Task<bool> UnlockAsync(IReadOnlyList<string> paths, bool breakLock)
    {
        if (paths.Count == 0) return false;
        Func<Task> retry = async () => { await UnlockAsync(paths, breakLock); };
        var result = await RunWriteAsync(breakLock ? "强制解除锁定" : "解除锁定",
            (credential, progress, cancellationToken) => _client!.InvokeAsync<UnlockOutcomeDto>("unlock",
                new { paths = paths.ToArray(), breakLock, confirmed = breakLock },
                progress, cancellationToken, credential), retry,
            breakLock ? "已强制解除锁定。" : "已解除锁定。");
        return result is not null;
    }

    public async Task<bool> CleanupAsync()
    {
        if (!HasWorkingCopy) return false;
        Func<Task> retry = async () => { await CleanupAsync(); };
        var result = await RunWriteAsync("清理工作副本",
            (credential, progress, cancellationToken) => _client!.InvokeAsync<OkDto>("cleanup",
                new { path = _workingCopyPath }, progress, cancellationToken, credential), retry,
            "Cleanup 完成。");
        return result is not null;
    }

    public async Task<bool> SetPropertyAsync(string name, string value, IReadOnlyList<string> targets)
    {
        if (targets.Count == 0) return false;
        Func<Task> retry = async () => { await SetPropertyAsync(name, value, targets); };
        var result = await RunWriteAsync("设置属性",
            (credential, progress, cancellationToken) => _client!.InvokeAsync<OkDto>("set_property",
                new { name, value, targets = targets.ToArray() }, progress, cancellationToken,
                credential), retry, $"已设置 {name}。");
        return result is not null;
    }

    public async Task<bool> DeletePropertyAsync(string name, IReadOnlyList<string> targets)
    {
        if (targets.Count == 0) return false;
        Func<Task> retry = async () => { await DeletePropertyAsync(name, targets); };
        var result = await RunWriteAsync("删除属性",
            (credential, progress, cancellationToken) => _client!.InvokeAsync<OkDto>("delete_property",
                new { name, targets = targets.ToArray() }, progress, cancellationToken, credential),
            retry, $"已删除属性 {name}。");
        return result is not null;
    }

    public async Task<bool> AddIgnorePatternAsync(string pattern, string directory)
    {
        Func<Task> retry = async () => { await AddIgnorePatternAsync(pattern, directory); };
        var result = await RunWriteAsync("忽略此文件类型",
            (credential, progress, cancellationToken) => _client!.InvokeAsync<OkDto>("add_ignore_pattern",
                new { pattern, directory }, progress, cancellationToken, credential), retry,
            $"已将 {pattern} 加入 svn:ignore。");
        return result is not null;
    }

    public async Task<bool> IgnoreAsync(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return false;
        Func<Task> retry = async () => { await IgnoreAsync(paths); };
        var result = await RunWriteAsync("忽略文件",
            (credential, progress, cancellationToken) => _client!.InvokeAsync<IgnoreOutcomeDto>("ignore",
                new { paths = paths.ToArray() }, progress, cancellationToken, credential), retry,
            null);
        if (result is null) return false;
        Notify(NotificationSeverity.Success, "已更新忽略列表",
            result.Added.Count == 0
                ? "这些文件已在忽略列表中。"
                : $"新增 {result.Added.Count} 条忽略规则。");
        return true;
    }

    public async Task<bool> CheckoutAsync(
        string url, string destination, long? revision, string depth)
    {
        Func<Task> retry = async () => { await CheckoutAsync(url, destination, revision, depth); };
        try
        {
            var result = await Tasks.RunAsync("检出 " + destination,
                async (progress, cancellationToken) =>
                {
                    await WithAuthAsync(async credential =>
                    {
                        await _client!.InvokeAsync<OkDto>("checkout", new
                        {
                            url,
                            destination,
                            revision,
                            depth,
                        }, progress, cancellationToken, credential);
                        return true;
                    }, true);
                    return true;
                }, retry, "检出完成");

            if (!result)
            {
                Notify(NotificationSeverity.Warning, "检出已取消",
                    "目标目录可能只下载了一部分；可以删除它后重试，或继续使用。");
                return false;
            }

            Connection = ConnectionState.Reachable;
            await OpenWorkingCopyAsync(destination);
            Notify(NotificationSeverity.Success, "检出完成", url);
            return true;
        }
        catch (OpenSVNException exception)
        {
            UpdateConnection(exception);
            ReportException(exception);
            return false;
        }
        catch (Exception exception)
        {
            Notify(NotificationSeverity.Error, "检出失败", exception.Message);
            return false;
        }
    }

    private Func<Task> BoundRetry(string? workingCopy, Func<Task> retry) => async () =>
    {
        if (!SamePath(workingCopy, _workingCopyPath))
        {
            throw new InvalidOperationException(
                "原工作副本已关闭或已切换，已阻止重试，以免对另一个工作副本执行旧操作。");
        }
        await retry();
    };

    private static bool SamePath(string? left, string? right) =>
        left is not null && right is not null &&
        string.Equals(left.TrimEnd('\\', '/'), right.TrimEnd('\\', '/'),
            StringComparison.OrdinalIgnoreCase);

    private async Task<T?> RunWriteAsync<T>(
        string title,
        Func<SVNCredential?, IProgress<string>, CancellationToken, Task<T>> action,
        Func<Task>? retry = null,
        string? successMessage = null,
        bool allowAuthPrompt = true,
        string cancelAdvice = "工作副本可能处于中间状态，必要时执行 Cleanup。") where T : class
    {
        var retryWorkingCopy = _workingCopyPath;
        var boundRetry = retry is null ? null : BoundRetry(retryWorkingCopy, retry);
        try
        {
            var result = await Tasks.RunAsync(title,
                (progress, cancellationToken) => WithAuthAsync(
                    credential => action(credential, progress, cancellationToken), allowAuthPrompt),
                boundRetry, successMessage);

            if (result is null)
            {
                Notify(NotificationSeverity.Warning, title + "已取消", cancelAdvice);
                return null;
            }

            await RefreshStatusAsync(silent: true);
            await RefreshJournalAsync();
            if (!string.IsNullOrWhiteSpace(successMessage))
            {
                Notify(NotificationSeverity.Success, title, successMessage);
            }
            return result;
        }
        catch (OpenSVNException exception)
        {
            ReportException(exception);
            return null;
        }
        catch (Exception exception)
        {
            Notify(NotificationSeverity.Error, title + "失败", exception.Message);
            return null;
        }
    }

    private async Task<T> WithAuthAsync<T>(
        Func<SVNCredential?, Task<T>> action, bool allowPrompt = true,
        Func<bool>? stillCurrent = null)
    {
        try
        {
            return await action(null);
        }
        catch (OpenSVNException exception) when (exception.AuthenticationRequired)
        {
            if (stillCurrent is not null && !stillCurrent()) throw;
            UpdateConnection(exception);
            if (!allowPrompt || CredentialRequested is null) throw;
            var credential = await CredentialRequested(RepositoryHost);
            if (credential is null) throw;
            if (stillCurrent is not null && !stillCurrent()) throw;
            return await action(credential);
        }
    }

    private void UpdateConnection(OpenSVNException exception)
    {
        if (exception.AuthenticationRequired)
        {
            Connection = ConnectionState.AuthenticationRequired;
        }
        else if (exception.Identifier is "SVN-0201" or "SVN-0401")
        {
            Connection = ConnectionState.Unreachable;
        }
    }

    private void ReportException(OpenSVNException exception)
    {
        if (exception.Cancelled)
        {
            Notify(NotificationSeverity.Warning, "操作已取消",
                "工作副本可能处于中间状态，必要时执行 Cleanup。");
            return;
        }

        UpdateConnection(exception);
        var message = exception.Message;
        if (!string.IsNullOrWhiteSpace(exception.Remediation)) message += "\n" + exception.Remediation;
        if (!string.IsNullOrWhiteSpace(exception.Detail)) message += "\n\n" + exception.Detail;
        Notify(NotificationSeverity.Error, $"操作失败（{exception.Identifier}）", message);
    }

    private void PersistSettings(string failureMessage)
    {
        try
        {
            _settings.Save();
        }
        catch (Exception exception)
        {
            Notify(NotificationSeverity.Warning, "设置未保存", failureMessage + "\n" + exception.Message);
        }
    }

    private void RefreshRecentWorkingCopies()
    {
        RecentWorkingCopies.Clear();
        foreach (var path in _settings.RecentWorkingCopies)
        {
            var name = Path.GetFileName(path.TrimEnd('\\', '/'));
            RecentWorkingCopies.Add(new RecentWorkingCopyItem
            {
                Path = path,
                DisplayName = string.IsNullOrWhiteSpace(name) ? path : name,
                IsAvailable = Directory.Exists(path),
            });
        }
        OnPropertyChanged(nameof(HasRecentWorkingCopies));
    }

    public void RemoveRecentWorkingCopy(string path)
    {
        _settings.RecentWorkingCopies.RemoveAll(
            item => string.Equals(item, path, StringComparison.OrdinalIgnoreCase));
        if (string.Equals(_settings.LastWorkingCopy, path, StringComparison.OrdinalIgnoreCase))
        {
            _settings.LastWorkingCopy = null;
        }
        PersistSettings("最近工作副本记录未能更新。");
        RefreshRecentWorkingCopies();
    }

    public void Notify(NotificationSeverity severity, string title, string message) =>
        Notification?.Invoke(severity, title, message);

    public void SetSelection(IEnumerable<StatusItem> items)
    {
        _selectedItems = items.ToList();
        OnPropertyChanged(nameof(SelectedItems));
        OnPropertyChanged(nameof(SelectionText));
    }

    public async Task RefreshJournalAsync()
    {
        if (_client is null) return;
        try
        {
            var journal = await _client.InvokeAsync<JournalDto>("journal", null);
            Journal = journal;
            JournalAvailable?.Invoke(journal);
        }
        catch
        {
            // The banner is advisory; an unreadable journal is reported separately.
        }
    }

    public async Task DiscardJournalEntryAsync(string id)
    {
        if (_client is null) return;
        try
        {
            await _client.InvokeAsync<OkDto>("discard_journal_entry", new { id });
            await RefreshJournalAsync();
        }
        catch (OpenSVNException exception)
        {
            ReportException(exception);
        }
    }

    public async Task DiscardAllJournalAsync()
    {
        if (_client is null) return;
        try
        {
            await _client.InvokeAsync<OkDto>("discard_all_journal", null);
            await RefreshJournalAsync();
        }
        catch (OpenSVNException exception)
        {
            ReportException(exception);
        }
    }

    public async Task<List<CredentialScopeDto>?> GetCredentialScopesAsync()
    {
        if (_client is null) return new List<CredentialScopeDto>();
        try
        {
            var result = await _client.InvokeAsync<CredentialScopesDto>("credential_scopes", null);
            return result.Scopes;
        }
        catch (OpenSVNException exception)
        {
            ReportException(exception);
            return null;
        }
    }

    public async Task ForgetCredentialAsync(CredentialScopeDto scope)
    {
        if (_client is null) return;
        try
        {
            await _client.InvokeAsync<OkDto>("forget_credential",
                new { host = scope.Host, realm = scope.Realm });
            Notify(NotificationSeverity.Success, "已删除凭据",
                $"{scope.Host}{(string.IsNullOrWhiteSpace(scope.Realm) ? "" : " · " + scope.Realm)}");
        }
        catch (OpenSVNException exception)
        {
            ReportException(exception);
        }
    }

    public async Task ForgetAllCredentialsAsync()
    {
        if (_client is null) return;
        try
        {
            await _client.InvokeAsync<OkDto>("forget_all_credentials", null);
            Notify(NotificationSeverity.Success, "已清除所有凭据", "下次访问仓库时需要重新登录。");
        }
        catch (OpenSVNException exception)
        {
            ReportException(exception);
        }
    }

    public async Task<InstallationDto> SaveSettingsAsync(AppSettings updated)
    {
        if (Tasks.IsBusy) throw new InvalidOperationException("请等待当前操作结束或先取消它。");
        var candidate = updated.Clone();
        var (client, installation) = await CreateClientAsync(candidate);
        try
        {
            candidate.Save();
        }
        catch
        {
            client.Dispose();
            throw;
        }
        var previous = _client;
        _client = client;
        previous?.Dispose();
        _settings = candidate;
        _sessionVersion++;
        OnPropertyChanged(nameof(HasSvn));
        RefreshRecentWorkingCopies();
        Installation = installation;
        OnPropertyChanged(nameof(Settings));
        SettingsChanged?.Invoke();

        if (HasWorkingCopy)
        {
            await LoadInfoAsync();
            await RefreshStatusAsync(silent: true);
        }
        await RefreshJournalAsync();
        Notify(NotificationSeverity.Success, "设置已保存",
            $"使用 svn {installation.Version}（{installation.Source}）。");
        return installation;
    }

    public void RaiseState()
    {
        OnPropertyChanged(nameof(HasWorkingCopy));
        OnPropertyChanged(nameof(HasNoWorkingCopy));
        OnPropertyChanged(nameof(StatusSummary));
        OnPropertyChanged(nameof(IsBusy));
        OnPropertyChanged(nameof(IsIdle));
        OnPropertyChanged(nameof(HasSvn));
    }

    public void Dispose()
    {
        _watcher.Dispose();
        Tasks.Dispose();
        _client?.Dispose();
        _client = null;
        _refreshGate.Dispose();
    }
}
