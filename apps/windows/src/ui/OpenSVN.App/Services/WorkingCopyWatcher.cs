namespace OpenSVN.App.Services;

/// <summary>
/// Watches the open working copy and asks for a status refresh after edits.
/// Changes under .svn are ignored: svn writes its stat cache there, and
/// reacting to that would make every refresh trigger the next one.
/// </summary>
public sealed class WorkingCopyWatcher : IDisposable
{
    private readonly Func<Task> _onChanged;
    private readonly SynchronizationContext? _context = SynchronizationContext.Current;
    private readonly System.Threading.Timer _debounce;
    private FileSystemWatcher? _watcher;
    private int _scheduled;

    public WorkingCopyWatcher(Func<Task> onChanged)
    {
        _onChanged = onChanged;
        _debounce = new System.Threading.Timer(OnDebounce, null, Timeout.Infinite, Timeout.Infinite);
    }

    public void Watch(string workingCopy)
    {
        Stop();
        try
        {
            var watcher = new FileSystemWatcher(workingCopy)
            {
                IncludeSubdirectories = true,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName |
                               NotifyFilters.LastWrite | NotifyFilters.Size |
                               NotifyFilters.Attributes | NotifyFilters.CreationTime,
                InternalBufferSize = 64 * 1024,
                EnableRaisingEvents = true,
            };
            watcher.Changed += OnWatcherEvent;
            watcher.Created += OnWatcherEvent;
            watcher.Deleted += OnWatcherEvent;
            watcher.Renamed += OnRenamed;
            watcher.Error += (_, _) => Schedule();
            _watcher = watcher;
        }
        catch
        {
            // A watcher is an optimization; a failed one must not block the app.
        }
    }

    public void Stop()
    {
        if (_watcher is null) return;
        _watcher.EnableRaisingEvents = false;
        _watcher.Dispose();
        _watcher = null;
    }

    private void OnWatcherEvent(object sender, FileSystemEventArgs args)
    {
        if (IsMetaPath(args.FullPath)) return;
        Schedule();
    }

    private void OnRenamed(object sender, RenamedEventArgs args)
    {
        if (IsMetaPath(args.FullPath) && IsMetaPath(args.OldFullPath)) return;
        Schedule();
    }

    /// Reschedules a refresh that could not run because another refresh or
    /// write held the working copy.
    public void RequestRefresh() => Schedule();

    private void Schedule()
    {
        if (Interlocked.Exchange(ref _scheduled, 1) == 1) return;
        try
        {
            _debounce.Change(700, Timeout.Infinite);
        }
        catch
        {
            Interlocked.Exchange(ref _scheduled, 0);
        }
    }

    private void OnDebounce(object? state)
    {
        Interlocked.Exchange(ref _scheduled, 0);
        void Run()
        {
            _ = SafeInvokeAsync();
        }

        if (_context is not null) _context.Post(_ => Run(), null);
        else Run();
    }

    private async Task SafeInvokeAsync()
    {
        try
        {
            await _onChanged();
        }
        catch
        {
            // Background refresh failures are normal while editors save files.
        }
    }

    private static bool IsMetaPath(string path)
    {
        var segments = path.Split(new[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries);
        return segments.Any(segment => string.Equals(segment, ".svn", StringComparison.OrdinalIgnoreCase));
    }

    public void Dispose()
    {
        Stop();
        _debounce.Dispose();
    }
}
