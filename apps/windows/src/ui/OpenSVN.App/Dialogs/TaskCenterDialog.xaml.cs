using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenSVN.App.Services;
using OpenSVN.App.ViewModels;
using System.Collections.Specialized;

namespace OpenSVN.App.Dialogs;

public sealed partial class TaskCenterDialog : ContentDialog
{
    private readonly MainViewModel _viewModel;

    public TaskCenterDialog(MainViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        Tasks = viewModel.Tasks;
        TaskList.ItemsSource = Tasks.Tasks;
        PrimaryButtonClick += OnClearFinished;
        Opened += (_, _) =>
        {
            UpdateEmptyState();
            Tasks.Tasks.CollectionChanged += OnTasksChanged;
        };
        Closed += (_, _) => Tasks.Tasks.CollectionChanged -= OnTasksChanged;
    }

    public TaskCenter Tasks { get; }

    private void OnTasksChanged(object? sender, NotifyCollectionChangedEventArgs e) => UpdateEmptyState();

    private void UpdateEmptyState()
    {
        EmptyText.Visibility = Tasks.Tasks.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        IsPrimaryButtonEnabled = Tasks.Tasks.Count > 0;
    }

    private void OnClearFinished(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true;
        Tasks.ClearFinished();
        UpdateEmptyState();
    }

    private void CancelCurrent_Click(object sender, RoutedEventArgs e) => Tasks.CancelCurrent();

    private async void Retry_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { DataContext: TaskRecord record } || record.RetryAction is null) return;
        var retry = record.RetryAction;
        record.RetryAction = null;
        Hide();
        try
        {
            await Task.Delay(120);
            await retry();
        }
        catch (Exception exception)
        {
            _viewModel.Notify(NotificationSeverity.Error, "重试失败", exception.Message);
        }
    }
}
