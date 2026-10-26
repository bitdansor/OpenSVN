using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using OpenSVN.App.Dialogs;
using OpenSVN.App.Models;
using OpenSVN.App.Services;
using OpenSVN.App.ViewModels;
using System.IO;
using System.Linq;
using Windows.ApplicationModel.DataTransfer;

namespace OpenSVN.App.Views;

public sealed partial class ChangesPage : Page
{
    private string[] _terms = Array.Empty<string>();
    private string[] _pendingTerms = Array.Empty<string>();
    private bool _suppressSelection;
    private HashSet<string> _selectionPaths = new(StringComparer.OrdinalIgnoreCase);
    private readonly DispatcherQueueTimer _filterTimer;

    public ChangesPage()
    {
        InitializeComponent();
        StatusList.ItemsSource = GroupedSource.View;
        _filterTimer = DispatcherQueue.CreateTimer();
        _filterTimer.Interval = TimeSpan.FromMilliseconds(180);
        _filterTimer.IsRepeating = false;
        _filterTimer.Tick += (_, _) =>
        {
            _filterTimer.Stop();
            _terms = _pendingTerms;
            Render();
        };
        Loaded += (_, _) => Render();
    }

    public MainViewModel ViewModel => App.ViewModel!;

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        ViewModel.StatusChanged += OnStatusChanged;
        Render();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        _filterTimer.Stop();
        ViewModel.StatusChanged -= OnStatusChanged;
        base.OnNavigatedFrom(e);
    }

    private void OnStatusChanged() => Render();

    private IReadOnlyList<StatusItem> SelectedItems =>
        StatusList.SelectedItems.OfType<StatusItem>().ToList();

    private void Render()
    {
        _selectionPaths = ViewModel.SelectedItems.Select(item => item.Path)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var all = ViewModel.StatusItems.ToList();
        var filtered = all.Where(Matches).ToList();
        var groups = filtered
            .GroupBy(item => item.Category)
            .OrderBy(group => Display.CategoryOrder(group.Key))
            .Select(group => new StatusGroup(group.Key, group))
            .ToList();

        _suppressSelection = true;
        GroupedSource.Source = groups;
        StatusList.SelectedItems.Clear();
        foreach (var item in filtered)
        {
            if (_selectionPaths.Contains(item.Path)) StatusList.SelectedItems.Add(item);
        }
        _suppressSelection = false;

        ViewModel.SetSelection(StatusList.SelectedItems.OfType<StatusItem>());
        UpdateCommands();

        var hasError = ViewModel.HasStatusError;
        StatusErrorBar.Message = ViewModel.StatusError ?? "";
        StatusErrorBar.IsOpen = hasError;
        CleanState.Visibility = all.Count == 0 && !hasError ? Visibility.Visible : Visibility.Collapsed;
        NoResultsState.Visibility = all.Count > 0 && filtered.Count == 0 && !hasError
            ? Visibility.Visible
            : Visibility.Collapsed;
        CountText.Text = hasError
            ? $"显示上次成功读取的 {all.Count} 项；当前状态未知"
            : $"显示 {filtered.Count} / {all.Count} 项";
        ConflictBanner.IsOpen = ViewModel.HasConflicts;
        ConflictBanner.Message = ViewModel.StatusItems.Count(item => item.IsConflicted) + " 个文件仍有冲突；请解决后再提交。";
    }

    private bool Matches(StatusItem item) =>
        _terms.Length == 0 ||
        _terms.All(term => item.DisplayPath.Contains(term, StringComparison.OrdinalIgnoreCase));

    private void FilterBox_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
        var terms = sender.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(term => term.Trim())
            .Where(term => term.Length > 0)
            .ToArray();
        if (terms.SequenceEqual(_pendingTerms)) return;
        _pendingTerms = terms;
        _filterTimer.Stop();
        _filterTimer.Start();
    }

    private void StatusList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelection) return;
        var selected = SelectedItems;
        _selectionPaths = selected.Select(item => item.Path)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        ViewModel.SetSelection(selected);
        UpdateCommands();
    }

    private void UpdateCommands()
    {
        var selected = SelectedItems;
        AddButton.IsEnabled = selected.Any(item => item.CanAdd);
        DeleteButton.IsEnabled = selected.Any(item => item.CanDelete);
        RevertButton.IsEnabled = selected.Any(item => item.CanRevert);
        ResolveButton.IsEnabled = selected.Any(item => item.IsConflicted);
        LockButton.IsEnabled = selected.Any(item => !item.IsUnversioned);
        UnlockButton.IsEnabled = selected.Any(item => item.HasLock);
        IgnoreButton.IsEnabled = selected.Any(item => item.IsUnversioned);
        PropertiesButton.IsEnabled = selected.Count == 1;
        DiffButton.IsEnabled = selected.Count == 1;
    }

    private async void Add_Click(object sender, RoutedEventArgs e)
    {
        var paths = SelectedItems.Where(item => item.CanAdd).Select(item => item.Path).ToList();
        if (paths.Count == 0) return;
        await ViewModel.AddAsync(paths);
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        var items = SelectedItems.Where(item => item.CanDelete).ToList();
        if (items.Count == 0) return;
        var paths = items.Select(item => item.Path).ToList();
        var preview = await ViewModel.PreviewDeleteAsync(paths);
        if (preview is null) return;

        var content = BuildPreviewContent(preview.Detail, preview.DiscardedPaths);
        var dialog = new ContentDialog
        {
            Title = $"删除 {paths.Count} 个路径并纳入提交",
            Content = content,
            PrimaryButtonText = "删除（会丢失本地修改）",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await ShowDialogAsync(dialog) == ContentDialogResult.Primary)
        {
            await ViewModel.DeleteAsync(paths);
        }
    }

    private async void Revert_Click(object sender, RoutedEventArgs e)
    {
        var items = SelectedItems.Where(item => item.CanRevert).ToList();
        if (items.Count == 0) return;
        var paths = items.Select(item => item.Path).ToList();
        var preview = await ViewModel.PreviewRevertAsync(paths);
        if (preview is null) return;

        var content = BuildPreviewContent(preview.Detail, preview.DiscardedPaths);
        content.Children.Add(new TextBlock
        {
            Text = "未纳入版本控制的文件不受影响。此操作不可撤销。",
            TextWrapping = TextWrapping.Wrap,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        var dialog = new ContentDialog
        {
            Title = $"还原 {paths.Count} 个路径的本地修改",
            Content = content,
            PrimaryButtonText = "还原（会丢失修改）",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await ShowDialogAsync(dialog) == ContentDialogResult.Primary)
        {
            await ViewModel.RevertAsync(paths, recursive: true);
        }
    }

    private async void Resolve_Click(object sender, RoutedEventArgs e)
    {
        var items = SelectedItems.Where(item => item.IsConflicted).ToList();
        if (items.Count == 0) return;
        var dialog = new ResolveDialog(items.Select(item => item.DisplayPath).ToList());
        if (await ShowDialogAsync(dialog) != ContentDialogResult.Primary) return;

        var paths = items.Select(item => item.Path).ToList();
        var outcome = await ViewModel.ResolveAsync(paths, dialog.Strategy, backup: true);
        if (outcome is null) return;
        var result = new ResolveResultDialog(outcome);
        await ShowDialogAsync(result);
    }

    private async void Lock_Click(object sender, RoutedEventArgs e)
    {
        var items = SelectedItems.Where(item => !item.IsUnversioned).ToList();
        if (items.Count == 0)
        {
            ViewModel.Notify(NotificationSeverity.Info, "没有可锁定的路径",
                "未纳入版本控制的文件不能加锁。");
            return;
        }

        var dialog = new LockDialog(items.Count);
        if (await ShowDialogAsync(dialog) != ContentDialogResult.Primary) return;
        await ViewModel.LockAsync(items.Select(item => item.Path).ToList(),
            dialog.Comment, dialog.Steal);
    }

    private async void Unlock_Click(object sender, RoutedEventArgs e)
    {
        var items = SelectedItems.Where(item => item.HasLock).ToList();
        if (items.Count == 0) return;

        var breakLock = items.Any(item => item.IsForeignLocked);
        if (breakLock)
        {
            var dialog = new ContentDialog
            {
                Title = "强制解除他人持有的锁",
                Content = new TextBlock
                {
                    Text = $"持有者（{string.Join("、", items.Where(item => item.IsForeignLocked)
                        .Select(item => Display.LockOwner(null, item.Entry.RemoteLock)).Distinct())}）将无法提交，直到发现锁已易主。",
                    TextWrapping = TextWrapping.Wrap,
                },
                PrimaryButtonText = "强制解除",
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await ShowDialogAsync(dialog) != ContentDialogResult.Primary) return;
        }

        await ViewModel.UnlockAsync(items.Select(item => item.Path).ToList(), breakLock);
    }

    private async void Ignore_Click(object sender, RoutedEventArgs e)
    {
        var items = SelectedItems.Where(item => item.IsUnversioned).ToList();
        if (items.Count == 0) return;

        var single = items.Count == 1 ? items[0] : null;
        var dialog = new ContentDialog
        {
            Title = single is null ? $"忽略 {items.Count} 个文件" : $"忽略「{single.DisplayPath}」",
            Content = new TextBlock
            {
                Text = "忽略只影响未纳入版本控制的文件，不会改变已跟踪的内容；可以随时编辑 svn:ignore 撤销。",
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = single is null ? "忽略这些文件" : "忽略此文件",
            SecondaryButtonText = single is not null && !string.IsNullOrEmpty(Path.GetExtension(single.Path))
                ? $"忽略所有 {Path.GetExtension(single.Path)} 文件"
                : "",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary,
        };

        var result = await ShowDialogAsync(dialog);
        if (result == ContentDialogResult.Primary)
        {
            await ViewModel.IgnoreAsync(items.Select(item => item.Path).ToList());
        }
        else if (result == ContentDialogResult.Secondary && single is not null)
        {
            var extension = Path.GetExtension(single.Path);
            var pattern = "*" + extension;
            var directory = Path.GetDirectoryName(single.Path) ?? ViewModel.WorkingCopyPath;
            await ViewModel.AddIgnorePatternAsync(pattern, directory);
        }
    }

    private void CopyPath_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuFlyoutItem { Tag: string path } || string.IsNullOrEmpty(path)) return;
        var package = new DataPackage();
        package.SetText(path);
        Clipboard.SetContent(package);
    }

    private void Properties_Click(object sender, RoutedEventArgs e)
    {
        var item = SelectedItems.FirstOrDefault();
        if (item is null) return;
        if (App.MainWindow is MainWindow window) window.ShowProperties(item.Path);
    }

    private async void Diff_Click(object sender, RoutedEventArgs e)
    {
        var item = SelectedItems.FirstOrDefault();
        if (item is not null) await ShowDiffAsync(item);
    }

    private async void StatusList_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        var item = SelectedItems.FirstOrDefault();
        if (item is not null) await ShowDiffAsync(item);
    }

    private async Task ShowDiffAsync(StatusItem item)
    {
        var diff = await ViewModel.LoadDiffAsync(item.Path);
        if (diff is null) return;
        var dialog = new DiffDialog($"{item.DisplayPath} · 工作副本差异", diff.Text,
            diff.IsTruncated, diff.ByteCount);
        await ShowDialogAsync(dialog);
    }

    private Task<ContentDialogResult> ShowDialogAsync(ContentDialog dialog) =>
        DialogCoordinator.ShowAsync(dialog, XamlRoot);

    private static StackPanel BuildPreviewContent(string detail, IReadOnlyList<string> discarded)
    {
        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(new TextBlock { Text = detail, TextWrapping = TextWrapping.Wrap });
        if (discarded.Count > 0)
        {
            var list = new StackPanel { Spacing = 2 };
            foreach (var path in discarded.Take(12))
            {
                list.Children.Add(new TextBlock
                {
                    Text = "· " + path,
                    TextWrapping = TextWrapping.Wrap,
                    FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"),
                    FontSize = 12,
                });
            }
            if (discarded.Count > 12)
            {
                list.Children.Add(new TextBlock { Text = $"…以及另外 {discarded.Count - 12} 个", FontSize = 12 });
            }
            content.Children.Add(new ScrollViewer { Content = list, MaxHeight = 240 });
        }
        return content;
    }
}
