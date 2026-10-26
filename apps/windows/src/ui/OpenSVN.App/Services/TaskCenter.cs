using OpenSVN.App.Native;
using OpenSVN.App.ViewModels;
using System.Collections.ObjectModel;
using System.ComponentModel;

namespace OpenSVN.App.Services;

public enum OperationState
{
    Running,
    Succeeded,
    Failed,
    Cancelled,
}

public sealed class TaskRecord : ObservableObject
{
    private string _detail = "";
    private OperationState _state = OperationState.Running;
    private string? _error;
    private string? _identifier;
    private Func<Task>? _retryAction;

    public TaskRecord(string title)
    {
        Title = title;
        StartedAt = DateTimeOffset.Now;
    }

    public string Title { get; }
    public DateTimeOffset StartedAt { get; }
    public DateTimeOffset? FinishedAt { get; private set; }

    public Func<Task>? RetryAction
    {
        get => _retryAction;
        set
        {
            if (ReferenceEquals(_retryAction, value)) return;
            _retryAction = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(IsRetryVisible));
        }
    }

    public string Detail
    {
        get => _detail;
        set => SetProperty(ref _detail, value);
    }

    public OperationState State
    {
        get => _state;
        set
        {
            if (!SetProperty(ref _state, value)) return;
            if (value != OperationState.Running) FinishedAt = DateTimeOffset.Now;
            OnPropertyChanged(nameof(StateText));
            OnPropertyChanged(nameof(IsRunning));
            OnPropertyChanged(nameof(IsRetryVisible));
            OnPropertyChanged(nameof(FinishedDisplay));
        }
    }

    public string? Error
    {
        get => _error;
        set
        {
            if (!SetProperty(ref _error, value)) return;
            OnPropertyChanged(nameof(HasError));
        }
    }

    public string? Identifier
    {
        get => _identifier;
        set => SetProperty(ref _identifier, value);
    }

    public string StateText => State switch
    {
        OperationState.Running => "进行中",
        OperationState.Succeeded => "已完成",
        OperationState.Failed => "失败",
        OperationState.Cancelled => "已取消",
        _ => "",
    };

    public bool IsRunning => State == OperationState.Running;
    public bool HasError => !string.IsNullOrWhiteSpace(Error);
    public bool IsRetryVisible => State == OperationState.Failed && RetryAction is not null;
    public string FinishedDisplay => FinishedAt is null ? "" : FinishedAt.Value.ToString("HH:mm:ss");
    public string TimeDisplay => StartedAt.ToString("HH:mm:ss") +
                                 (FinishedAt is null ? "" : " → " + FinishedAt.Value.ToString("HH:mm:ss"));
}

public sealed class TaskCenter : ObservableObject, IDisposable
{
    private TaskRecord? _currentTask;
    private bool _isBusy;
    private CancellationTokenSource? _currentCancellation;

    public TaskCenter()
    {
        Tasks.CollectionChanged += (_, _) => OnPropertyChanged(nameof(TaskCount));
    }

    public ObservableCollection<TaskRecord> Tasks { get; } = new();
    public TaskRecord? CurrentTask
    {
        get => _currentTask;
        private set
        {
            if (ReferenceEquals(_currentTask, value)) return;
            if (_currentTask is not null) _currentTask.PropertyChanged -= OnCurrentTaskChanged;
            _currentTask = value;
            if (_currentTask is not null) _currentTask.PropertyChanged += OnCurrentTaskChanged;
            OnPropertyChanged();
            OnPropertyChanged(nameof(CurrentDetail));
        }
    }

    private void OnCurrentTaskChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(TaskRecord.Detail))
        {
            OnPropertyChanged(nameof(CurrentDetail));
        }
    }

    public bool IsBusy
    {
        get => _isBusy;
        private set
        {
            if (SetProperty(ref _isBusy, value)) OnPropertyChanged(nameof(IsIdle));
        }
    }

    public bool IsIdle => !IsBusy;
    public int TaskCount => Tasks.Count;
    public string CurrentDetail => CurrentTask?.Detail ?? "";

    public void CancelCurrent() => _currentCancellation?.Cancel();

    public async Task<T?> RunAsync<T>(
        string title,
        Func<IProgress<string>, CancellationToken, Task<T>> action,
        Func<Task>? retry = null,
        string? successDetail = null)
    {
        if (IsBusy) throw new InvalidOperationException("另一个操作正在进行");

        var record = new TaskRecord(title) { RetryAction = retry };
        Tasks.Insert(0, record);
        while (Tasks.Count > 50) Tasks.RemoveAt(Tasks.Count - 1);

        using var cancellation = new CancellationTokenSource();
        _currentCancellation = cancellation;
        CurrentTask = record;
        IsBusy = true;

        var progress = new Progress<string>(line =>
        {
            if (!string.IsNullOrWhiteSpace(line)) record.Detail = line.TrimEnd();
        });

        try
        {
            var result = await action(progress, cancellation.Token);
            record.State = OperationState.Succeeded;
            record.Detail = successDetail ?? "完成";
            return result;
        }
        catch (OperationCanceledException)
        {
            record.State = OperationState.Cancelled;
            record.Detail = "已取消";
            return default;
        }
        catch (OpenSVNException exception) when (exception.Cancelled)
        {
            record.State = OperationState.Cancelled;
            record.Detail = "已取消";
            record.Identifier = exception.Identifier;
            return default;
        }
        catch (OpenSVNException exception)
        {
            record.State = OperationState.Failed;
            record.Error = exception.Message;
            record.Identifier = exception.Identifier;
            record.Detail = string.IsNullOrWhiteSpace(exception.Detail) ? exception.Message : exception.Detail!;
            if (!RetryIsSafe(exception)) record.RetryAction = null;
            throw;
        }
        catch (Exception exception)
        {
            record.State = OperationState.Failed;
            record.Error = exception.Message;
            record.Detail = exception.Message;
            record.RetryAction = null;
            throw;
        }
        finally
        {
            _currentCancellation = null;
            CurrentTask = null;
            IsBusy = false;
        }
    }

    public async Task<T?> RunReadAsync<T>(
        Func<IProgress<string>, CancellationToken, Task<T>> action,
        CancellationToken cancellationToken)
    {
        var progress = new Progress<string>(_ => { });
        return await action(progress, cancellationToken);
    }

    private static bool RetryIsSafe(OpenSVNException exception) =>
        exception.Identifier is not ("SVN-0201" or "SVN-0401" or "SVN-0402" or
            "SVN-9002" or "SVN-9998" or "SVN-9999");

    public void ClearFinished()
    {
        for (var index = Tasks.Count - 1; index >= 0; index--)
        {
            if (Tasks[index].State != OperationState.Running) Tasks.RemoveAt(index);
        }
    }

    public void Dispose()
    {
        _currentCancellation?.Cancel();
    }
}
