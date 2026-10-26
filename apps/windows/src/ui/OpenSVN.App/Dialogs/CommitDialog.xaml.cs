using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenSVN.App.Models;
using OpenSVN.App.Native;
using OpenSVN.App.ViewModels;
using System.Linq;
using Windows.ApplicationModel.DataTransfer;

namespace OpenSVN.App.Dialogs;

public sealed partial class CommitDialog : ContentDialog
{
    private readonly MainViewModel _viewModel;
    private readonly List<StatusItem> _candidates;
    private bool _committing;
    private int _previewVersion;

    public CommitDialog(MainViewModel viewModel, List<StatusItem> candidates, bool hasConflicts)
    {
        InitializeComponent();
        _viewModel = viewModel;
        _candidates = candidates;
        Title = candidates.Count == 1 ? "提交 1 个路径" : $"提交 {candidates.Count} 个路径";
        ConflictBanner.IsOpen = hasConflicts;
        PathsList.ItemsSource = candidates;
        RecentBox.ItemsSource = viewModel.RecentMessages.Messages;
        NoPathsText.Visibility = candidates.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Opened += OnOpened;
        Closed += OnClosed;
        PrimaryButtonClick += OnPrimary;
        Closing += (_, _) =>
        {
            if (_committing) _viewModel.Tasks.CancelCurrent();
        };
        UpdatePrimaryState();
    }

    private void OnOpened(ContentDialog sender, ContentDialogOpenedEventArgs args)
    {
        foreach (var candidate in _candidates) PathsList.SelectedItems.Add(candidate);
        MessageBox.Focus(FocusState.Programmatic);
        UpdatePrimaryState();
        _ = PreviewSelectedAsync();
    }

    private void OnClosed(ContentDialog sender, ContentDialogClosedEventArgs args)
    {
        // The operation is cancelled in Closing so the dialog cannot hide a
        // still-running write; VM notifications carry the final state.
    }

    private void MessageBox_TextChanged(object sender, TextChangedEventArgs e) => UpdatePrimaryState();

    private void PathsList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        NoPathsText.Visibility = PathsList.SelectedItems.Count == 0
            ? Visibility.Visible
            : Visibility.Collapsed;
        UpdatePrimaryState();
        _ = PreviewSelectedAsync();
    }

    private void CopyPath_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuFlyoutItem { Tag: string path } || string.IsNullOrEmpty(path)) return;
        var package = new DataPackage();
        package.SetText(path);
        Clipboard.SetContent(package);
    }

    private void Recent_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (RecentBox.SelectedItem is string message && !string.IsNullOrWhiteSpace(message))
        {
            MessageBox.Text = message;
        }
    }

    private void UpdatePrimaryState()
    {
        IsPrimaryButtonEnabled = !_committing &&
                                 MessageBox.Text.Trim().Length > 0 &&
                                 PathsList.SelectedItems.Count > 0;
    }

    private async Task PreviewSelectedAsync()
    {
        var item = PathsList.SelectedItems.OfType<StatusItem>().FirstOrDefault();
        if (item is null)
        {
            PreviewLabel.Text = "差异预览";
            PreviewDiff.SetText(null);
            return;
        }

        var version = ++_previewVersion;
        PreviewLabel.Text = "差异预览：" + item.DisplayPath;
        PreviewRing.IsActive = true;
        PreviewRing.Visibility = Visibility.Visible;
        try
        {
            var diff = await _viewModel.LoadDiffAsync(item.Path);
            if (version != _previewVersion) return;
            PreviewDiff.SetText(diff?.Text, diff?.IsTruncated ?? false, diff?.ByteCount ?? 0);
        }
        finally
        {
            if (version == _previewVersion)
            {
                PreviewRing.IsActive = false;
                PreviewRing.Visibility = Visibility.Collapsed;
            }
        }
    }

    private async void OnPrimary(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true;
        if (_committing) return;
        var paths = PathsList.SelectedItems.OfType<StatusItem>().Select(item => item.Path).ToList();
        var message = MessageBox.Text.Trim();
        if (paths.Count == 0 || message.Length == 0) return;
        await CommitAsync(paths, message, null);
    }

    private async void AuthRetry_Click(object sender, RoutedEventArgs e)
    {
        var username = UsernameBox.Text.Trim();
        if (username.Length == 0)
        {
            ShowMessage("需要认证", "用户名不能为空。", InfoBarSeverity.Warning);
            UsernameBox.Focus(FocusState.Programmatic);
            return;
        }

        var paths = PathsList.SelectedItems.OfType<StatusItem>().Select(item => item.Path).ToList();
        if (paths.Count == 0)
        {
            ShowMessage("无法提交", "至少选择一个路径。", InfoBarSeverity.Warning);
            return;
        }
        await CommitAsync(paths, MessageBox.Text.Trim(), new SVNCredential(username, PasswordBox.Password));
    }

    private async Task CommitAsync(IReadOnlyList<string> paths, string message, SVNCredential? credential)
    {
        _committing = true;
        AuthPanel.Visibility = Visibility.Collapsed;
        BusyPanel.Visibility = Visibility.Visible;
        ErrorBar.IsOpen = false;
        UpdatePrimaryState();

        try
        {
            var summary = await _viewModel.CommitAsync(paths, message, credential, allowAuthPrompt: false);
            if (summary is null)
            {
                ShowMessage("提交已取消", "提交说明与勾选已保留。", InfoBarSeverity.Warning);
                return;
            }
            Hide();
        }
        catch (OpenSVNException exception) when (exception.AuthenticationRequired)
        {
            ShowMessage("需要认证",
                $"{exception.Message}。请输入凭据后重试，提交说明与勾选不会丢失。",
                InfoBarSeverity.Warning);
            AuthHostText.Text = "主机：" + _viewModel.RepositoryHost +
                                (string.IsNullOrWhiteSpace(_viewModel.RepositoryUrl)
                                    ? ""
                                    : " · " + _viewModel.RepositoryUrl);
            AuthPanel.Visibility = Visibility.Visible;
            UsernameBox.Focus(FocusState.Programmatic);
        }
        catch (OpenSVNException exception)
        {
            var messageText = $"{exception.Identifier} {exception.Message}";
            if (!string.IsNullOrWhiteSpace(exception.Remediation))
                messageText += "\n" + exception.Remediation;
            if (!string.IsNullOrWhiteSpace(exception.Detail))
                messageText += "\n\n" + exception.Detail;
            ShowMessage("提交失败", messageText, InfoBarSeverity.Error);
        }
        catch (Exception exception)
        {
            ShowMessage("提交失败", exception.Message, InfoBarSeverity.Error);
        }
        finally
        {
            _committing = false;
            BusyPanel.Visibility = Visibility.Collapsed;
            UpdatePrimaryState();
        }
    }

    private void CancelCommit_Click(object sender, RoutedEventArgs e) =>
        _viewModel.Tasks.CancelCurrent();

    private void ShowMessage(string title, string message, InfoBarSeverity severity)
    {
        ErrorBar.Severity = severity;
        ErrorBar.Title = title;
        ErrorBar.Message = message;
        ErrorBar.IsOpen = true;
    }
}
