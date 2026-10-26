using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenSVN.App.Dialogs;
using OpenSVN.App.Models;
using OpenSVN.App.Native;
using OpenSVN.App.Services;
using OpenSVN.App.ViewModels;
using OpenSVN.App.Views;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;

namespace OpenSVN.App;

public sealed partial class MainWindow : Window
{
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    private bool _loaded;
    private bool _journalNotification;

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        TrySetWindowIcon();
        try
        {
            var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary);
            var work = area.WorkArea;
            var dpi = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
            var scale = dpi / 96.0;
            var margin = (int)(40 * scale);
            var width = Math.Min((int)(1240 * scale),
                Math.Max((int)(640 * scale), work.Width - margin * 2));
            var height = Math.Min((int)(820 * scale),
                Math.Max((int)(480 * scale), work.Height - margin * 2));
            width = Math.Min(width, work.Width);
            height = Math.Min(height, work.Height);
            AppWindow.Resize(new Windows.Graphics.SizeInt32(width, height));
        }
        catch
        {
            // The default size is acceptable when the window is not ready yet.
        }

        App.ViewModel = ViewModel;
        RootGrid.DataContext = ViewModel;
        ViewModel.Notification += OnNotification;
        ViewModel.WorkingCopyChanged += OnWorkingCopyChanged;
        ViewModel.JournalAvailable += OnJournalAvailable;
        ViewModel.CredentialRequested += OnCredentialRequested;
        ViewModel.SettingsChanged += OnSettingsChanged;
        Closed += OnClosed;

        ContentFrame.Navigate(typeof(ChangesPage));
    }

    public MainViewModel ViewModel { get; } = new();
    public string VersionText { get; } = AppInfo.Version;

    private void TrySetWindowIcon()
    {
        try
        {
            var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "opensvn.ico");
            if (File.Exists(iconPath)) AppWindow.SetIcon(iconPath);
        }
        catch
        {
            // The executable's embedded icon is the fallback.
        }
    }

    private async void RootGrid_Loaded(object sender, RoutedEventArgs e)
    {
        if (_loaded) return;
        _loaded = true;
        await ViewModel.InitializeAsync();
        UpdateShell();
    }

    private void UpdateShell()
    {
        var hasWorkingCopy = ViewModel.HasWorkingCopy;
        WelcomeRoot.Visibility = hasWorkingCopy ? Visibility.Collapsed : Visibility.Visible;
        WorkspaceRoot.Visibility = hasWorkingCopy ? Visibility.Visible : Visibility.Collapsed;

        if (hasWorkingCopy)
        {
            if (Navigation.SelectedItem is null)
            {
                Navigation.SelectedItem = ChangesItem;
            }
            else if (ReferenceEquals(Navigation.SelectedItem, ChangesItem) &&
                     ContentFrame.CurrentSourcePageType != typeof(ChangesPage))
            {
                ContentFrame.Navigate(typeof(ChangesPage));
            }
        }
        else
        {
            Navigation.SelectedItem = null;
        }
    }

    private void OnWorkingCopyChanged() =>
        DispatcherQueue.TryEnqueue(UpdateShell);

    private void OnSettingsChanged() =>
        DispatcherQueue.TryEnqueue(UpdateShell);

    private void OnNotification(NotificationSeverity severity, string title, string message)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            NotificationBar.Severity = severity switch
            {
                NotificationSeverity.Success => InfoBarSeverity.Success,
                NotificationSeverity.Warning => InfoBarSeverity.Warning,
                NotificationSeverity.Error => InfoBarSeverity.Error,
                _ => InfoBarSeverity.Informational,
            };
            NotificationBar.Title = title;
            NotificationBar.Message = message;
            NotificationBar.IsOpen = true;
            NotificationActionButton.Visibility = Visibility.Collapsed;
            _journalNotification = false;
        });
    }

    private void OnJournalAvailable(JournalDto journal)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            var warning = journal.Entries.Count > 0 ||
                          !string.IsNullOrWhiteSpace(journal.Quarantined) ||
                          !string.IsNullOrWhiteSpace(journal.WriteFailure);
            if (!warning)
            {
                if (_journalNotification)
                {
                    NotificationBar.IsOpen = false;
                    _journalNotification = false;
                }
                return;
            }

            if (NotificationBar.IsOpen && NotificationBar.Severity == InfoBarSeverity.Error)
            {
                return;
            }

            var message = journal.Entries.Count > 0
                ? $"上次有 {journal.Entries.Count} 个写操作没有记录结果。请先刷新确认工作副本状态。"
                : "";
            if (!string.IsNullOrWhiteSpace(journal.Quarantined))
            {
                message += (message.Length > 0 ? "\n" : "") + "损坏的操作日志已被隔离：" + journal.Quarantined;
            }
            if (!string.IsNullOrWhiteSpace(journal.WriteFailure))
            {
                message += (message.Length > 0 ? "\n" : "") + "写入操作日志失败：" + journal.WriteFailure;
            }

            NotificationBar.Severity = InfoBarSeverity.Warning;
            NotificationBar.Title = "需要留意上次的写操作";
            NotificationBar.Message = message.Trim();
            NotificationBar.IsOpen = true;
            NotificationActionButton.Content = journal.Entries.Count > 0 ? "查看未完成操作" : "知道了";
            NotificationActionButton.Visibility = Visibility.Visible;
            _journalNotification = true;
        });
    }

    private async Task<SVNCredential?> OnCredentialRequested(string host)
    {
        var dialog = new AuthDialog(host, ViewModel.RepositoryUrl);
        var result = await ShowDialogAsync(dialog);
        return result == ContentDialogResult.Primary
            ? new SVNCredential(dialog.Username, dialog.Password)
            : null;
    }

    private Task<ContentDialogResult> ShowDialogAsync(ContentDialog dialog) =>
        DialogCoordinator.ShowAsync(dialog, RootGrid.XamlRoot);

    private async void OpenWorkingCopy_Click(object sender, RoutedEventArgs e)
    {
        var path = await PickFolderAsync();
        if (path is null) return;
        await ViewModel.OpenWorkingCopyAsync(path);
        UpdateShell();
    }

    private async void RecentWorkingCopy_Click(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not RecentWorkingCopyItem item) return;
        var path = item.Path;
        if (!Directory.Exists(path))
        {
            path = await PickFolderAsync();
            if (path is null) return;
            if (!await ViewModel.OpenWorkingCopyAsync(path)) return;
            if (!string.Equals(path.TrimEnd('\\', '/'), item.Path.TrimEnd('\\', '/'),
                    StringComparison.OrdinalIgnoreCase))
            {
                ViewModel.RemoveRecentWorkingCopy(item.Path);
            }
        }
        else if (!await ViewModel.OpenWorkingCopyAsync(path))
        {
            return;
        }
        UpdateShell();
    }

    private async Task<string?> PickFolderAsync()
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker,
            WinRT.Interop.WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        return folder?.Path;
    }

    private async void Checkout_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new CheckoutDialog();
        var result = await ShowDialogAsync(dialog);
        if (result != ContentDialogResult.Primary) return;

        await ViewModel.CheckoutAsync(dialog.RepositoryUrl, dialog.Destination,
            dialog.Revision, dialog.Depth);
        UpdateShell();
    }

    private async void WelcomeSettings_Click(object sender, RoutedEventArgs e)
    {
        var control = new SettingsControl(ViewModel, true);
        var dialog = new ContentDialog
        {
            Title = "设置 svn",
            Content = control,
            PrimaryButtonText = "关闭",
            DefaultButton = ContentDialogButton.Primary,
        };
        // MaxWidth/MinWidth on ContentDialog itself also cap the smoke layer, which
        // pulls the dialog off-centre; the template reads its panel size from these.
        dialog.Resources["ContentDialogMinWidth"] = 620.0;
        dialog.Resources["ContentDialogMaxWidth"] = 760.0;
        await ShowDialogAsync(dialog);
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) =>
        await ViewModel.RefreshStatusAsync();

    private async void Update_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel.IsBusy)
        {
            ViewModel.Notify(NotificationSeverity.Warning, "操作进行中", "请等待当前操作结束或取消它。");
            return;
        }

        if (ViewModel.Settings.AutoPreviewUpdate)
        {
            UpdatePreviewAttempt attempt;
            try
            {
                attempt = await ViewModel.PreviewUpdateAsync();
            }
            catch (Exception exception)
            {
                ViewModel.Notify(NotificationSeverity.Error, "无法预览更新", exception.Message);
                return;
            }

            if (!ViewModel.IsCurrentWorkingCopy(attempt.WorkingCopy, attempt.Session))
            {
                ViewModel.Notify(NotificationSeverity.Warning, "工作副本已切换",
                    "旧的更新预览已丢弃，请对当前工作副本重新发起更新。");
                return;
            }

            var dialog = new UpdatePreviewDialog(attempt.Preview, attempt.Error,
                ViewModel.ChangedCount, ViewModel.HasConflicts);
            var result = await ShowDialogAsync(dialog);
            if (result != ContentDialogResult.Primary) return;

            if (!ViewModel.IsCurrentWorkingCopy(attempt.WorkingCopy, attempt.Session))
            {
                ViewModel.Notify(NotificationSeverity.Warning, "工作副本已切换",
                    "旧的更新确认已丢弃，请对当前工作副本重新发起更新。");
                return;
            }

            await ViewModel.UpdateAsync(attempt.Preview?.ServerRevision,
                attempt.WorkingCopy, attempt.Session);
            return;
        }

        await ViewModel.UpdateAsync();
    }

    private async void Commit_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel.IsBusy)
        {
            ViewModel.Notify(NotificationSeverity.Warning, "操作进行中", "请等待当前操作结束或取消它。");
            return;
        }

        var selected = ViewModel.SelectedItems.Where(item => item.IsCommittable).ToList();
        var candidates = selected.Count > 0 ? selected : ViewModel.CommittableItems.ToList();
        if (candidates.Count == 0)
        {
            ViewModel.Notify(NotificationSeverity.Info, "没有可提交的改动",
                "未纳入版本控制的文件需要先 Add；冲突需要先解决。");
            return;
        }

        var dialog = new CommitDialog(ViewModel, candidates, ViewModel.HasConflicts);
        await ShowDialogAsync(dialog);
    }

    private async void RefreshLocks_Click(object sender, RoutedEventArgs e) =>
        await ViewModel.RefreshRemoteStatusAsync();

    private async void Cleanup_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            Title = "清理工作副本",
            Content = new TextBlock
            {
                Text = "Cleanup 会清除工作副本内部的锁并恢复中断的操作。它不会丢弃你的本地修改。",
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = "执行 Cleanup",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await ShowDialogAsync(dialog) == ContentDialogResult.Primary)
        {
            await ViewModel.CleanupAsync();
        }
    }

    private void CloseWorkingCopy_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel.CloseWorkingCopy()) UpdateShell();
    }

    private async void ShowJournal_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new JournalDialog(ViewModel);
        await ShowDialogAsync(dialog);
    }

    private async void ShowTasks_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new TaskCenterDialog(ViewModel);
        await ShowDialogAsync(dialog);
    }

    private void CancelCurrent_Click(object sender, RoutedEventArgs e) =>
        ViewModel.Tasks.CancelCurrent();

    private async void NotificationAction_Click(object sender, RoutedEventArgs e)
    {
        if (!_journalNotification)
        {
            NotificationBar.IsOpen = false;
            return;
        }
        await ShowJournalForNotificationAsync();
    }

    private async Task ShowJournalForNotificationAsync()
    {
        var dialog = new JournalDialog(ViewModel);
        await ShowDialogAsync(dialog);
    }

    public void ShowProperties(string path)
    {
        ViewModel.PropertiesTarget = path;
        if (ContentFrame.CurrentSourcePageType == typeof(PropertiesPage))
        {
            ContentFrame.Navigate(typeof(PropertiesPage));
        }
        else
        {
            Navigation.SelectedItem = PropertiesItem;
        }
    }

    private void Navigation_SelectionChanged(NavigationView sender,
        NavigationViewSelectionChangedEventArgs args)
    {        if (args.IsSettingsSelected)
        {
            if (ContentFrame.CurrentSourcePageType != typeof(SettingsPage))
            {
                ContentFrame.Navigate(typeof(SettingsPage));
            }
            return;
        }

        if (args.SelectedItemContainer?.Tag is not string tag) return;
        var page = tag switch
        {
            "changes" => typeof(ChangesPage),
            "history" => typeof(HistoryPage),
            "properties" => typeof(PropertiesPage),
            "info" => typeof(InfoPage),
            _ => null,
        };
        if (page is not null && ContentFrame.CurrentSourcePageType != page)
        {
            ContentFrame.Navigate(page);
        }
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        ViewModel.Notification -= OnNotification;
        ViewModel.WorkingCopyChanged -= OnWorkingCopyChanged;
        ViewModel.JournalAvailable -= OnJournalAvailable;
        ViewModel.CredentialRequested -= OnCredentialRequested;
        ViewModel.SettingsChanged -= OnSettingsChanged;
        ViewModel.Dispose();
    }
}
