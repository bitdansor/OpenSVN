using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenSVN.App.Dialogs;
using OpenSVN.App.Models;
using OpenSVN.App.Services;
using OpenSVN.App.ViewModels;
using System.Collections.ObjectModel;
using System.Linq;

namespace OpenSVN.App.Views;

public sealed partial class HistoryPage : Page
{
    private readonly ObservableCollection<LogEntryDto> _entries = new();
    private int _loadVersion;
    private bool _hasMore;
    private string? _loadedPath;

    public HistoryPage()
    {
        InitializeComponent();
        LogList.ItemsSource = _entries;
    }

    public MainViewModel ViewModel => App.ViewModel!;

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        ViewModel.WorkingCopyChanged += OnWorkingCopyChanged;
        if (_loadedPath != ViewModel.WorkingCopyPath)
        {
            _loadedPath = ViewModel.WorkingCopyPath;
            _entries.Clear();
            await LoadAsync(append: false);
        }
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        _loadVersion++;
        ViewModel.WorkingCopyChanged -= OnWorkingCopyChanged;
        base.OnNavigatedFrom(e);
    }

    private async void OnWorkingCopyChanged()
    {
        _loadedPath = ViewModel.WorkingCopyPath;
        _entries.Clear();
        ShowDetail(null);
        await LoadAsync(append: false);
    }

    private async Task LoadAsync(bool append)
    {
        var workingCopy = ViewModel.WorkingCopyPath;
        var version = ++_loadVersion;
        if (string.IsNullOrWhiteSpace(workingCopy))
        {
            LoadingRing.IsActive = false;
            LoadMoreButton.Visibility = Visibility.Collapsed;
            EmptyLogState.Visibility = Visibility.Collapsed;
            ErrorBar.IsOpen = false;
            return;
        }

        ErrorBar.IsOpen = false;
        EmptyLogState.Visibility = Visibility.Collapsed;
        LoadingRing.IsActive = true;
        LoadMoreButton.IsEnabled = false;
        if (!append) LoadMoreButton.Visibility = Visibility.Collapsed;
        try
        {
            long? endRevision = append && _entries.Count > 0
                ? _entries.Min(entry => entry.Revision) - 1
                : null;
            if (append && endRevision is <= 0)
            {
                _hasMore = false;
                LoadMoreButton.Visibility = Visibility.Collapsed;
                return;
            }

            var page = await ViewModel.LoadLogAsync(50, endRevision);
            if (version != _loadVersion ||
                !string.Equals(workingCopy, ViewModel.WorkingCopyPath,
                    StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
            if (page is null)
            {
                ErrorBar.Message = "无法加载历史记录。请检查网络或凭据，查看上方通知后重试。";
                ErrorBar.IsOpen = true;
                EmptyLogState.Visibility = _entries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
                return;
            }

            if (!append) _entries.Clear();
            foreach (var entry in page.Entries)
            {
                if (_entries.All(existing => existing.Revision != entry.Revision))
                {
                    _entries.Add(entry);
                }
            }

            _hasMore = page.HasMore;
            EmptyLogState.Visibility = _entries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            LoadMoreButton.Visibility = _hasMore ? Visibility.Visible : Visibility.Collapsed;
        }
        finally
        {
            if (version == _loadVersion)
            {
                LoadMoreButton.IsEnabled = true;
                LoadingRing.IsActive = false;
            }
        }
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) =>
        await LoadAsync(append: false);

    private async void LoadMore_Click(object sender, RoutedEventArgs e) => await LoadAsync(append: true);

    private void LogList_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        ShowDetail(LogList.SelectedItem as LogEntryDto);

    private void ShowDetail(LogEntryDto? entry)
    {
        if (entry is null)
        {
            EmptyDetail.Visibility = Visibility.Visible;
            DetailScroll.Visibility = Visibility.Collapsed;
            return;
        }

        EmptyDetail.Visibility = Visibility.Collapsed;
        DetailScroll.Visibility = Visibility.Visible;
        DetailHeader.Text = $"r{entry.Revision}";
        DetailMeta.Text = $"{entry.AuthorDisplay} · {entry.DateDisplay}";
        DetailMessage.Text = entry.Message;
        ChangedPathsList.ItemsSource = entry.ChangedPaths;
        ViewDiffButton.Tag = entry;
        ViewDiffButton.IsEnabled = true;
    }

    private async void ViewDiff_Click(object sender, RoutedEventArgs e)
    {
        if (ViewDiffButton.Tag is not LogEntryDto entry) return;
        ViewDiffButton.IsEnabled = false;
        try
        {
            var diff = await ViewModel.LoadRevisionDiffAsync(ViewModel.WorkingCopyPath, entry.Revision);
            if (diff is null) return;
            var dialog = new DiffDialog($"r{entry.Revision} · 修订差异", diff.Text,
                diff.IsTruncated, diff.ByteCount);
            await DialogCoordinator.ShowAsync(dialog, XamlRoot);
        }
        finally
        {
            ViewDiffButton.IsEnabled = true;
        }
    }
}
