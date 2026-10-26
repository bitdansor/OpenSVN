using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenSVN.App.Dialogs;
using OpenSVN.App.Models;
using OpenSVN.App.Native;
using OpenSVN.App.Services;
using OpenSVN.App.ViewModels;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using Windows.Storage.Pickers;

namespace OpenSVN.App.Views;

public sealed partial class SettingsControl : UserControl
{
    private readonly MainViewModel _viewModel;
    private readonly bool _isDialog;
    private readonly ObservableCollection<CredentialScopeDto> _scopes = new();
    private bool _eventsAttached;
    private bool _clearArmed;

    public SettingsControl() : this(App.ViewModel ?? throw new InvalidOperationException("应用尚未初始化"),
        isDialog: false)
    {
    }

    public SettingsControl(MainViewModel viewModel, bool isDialog)
    {
        InitializeComponent();
        _viewModel = viewModel;
        _isDialog = isDialog;
        CredentialsList.ItemsSource = _scopes;
        JournalButton.Visibility = isDialog ? Visibility.Collapsed : Visibility.Visible;
        DataDirectoryText.Text = AppSettings.DataDirectory;
        LoadSettingsToFields();
        RefreshInstallationText();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_eventsAttached) return;
        _eventsAttached = true;
        _viewModel.PropertyChanged += OnViewModelPropertyChanged;
        _viewModel.SettingsChanged += OnSettingsChanged;
        _ = RefreshCredentialsAsync();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (!_eventsAttached) return;
        _eventsAttached = false;
        _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
        _viewModel.SettingsChanged -= OnSettingsChanged;
    }

    private void OnViewModelPropertyChanged(object? sender,
        System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(MainViewModel.InstallationSummary) or nameof(MainViewModel.HasSvn))
        {
            RefreshInstallationText();
        }
    }

    private void OnSettingsChanged() => RefreshInstallationText();

    private void LoadSettingsToFields()
    {
        var settings = _viewModel.Settings;
        SvnPathBox.Text = settings.SvnPath ?? "";
        TimeoutBox.Value = settings.TimeoutSeconds;
        AutoPreviewToggle.IsOn = settings.AutoPreviewUpdate;
    }

    private void RefreshInstallationText() =>
        InstallationText.Text = "当前：" + _viewModel.InstallationSummary;

    private async void BrowseSvn_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".exe");
        picker.SuggestedStartLocation = PickerLocationId.ComputerFolder;
        WinRT.Interop.InitializeWithWindow.Initialize(picker,
            WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        var file = await picker.PickSingleFileAsync();
        if (file is not null) SvnPathBox.Text = file.Path;
    }

    private async void Save_Click(object sender, RoutedEventArgs e)
    {
        var settings = _viewModel.Settings.Clone();
        settings.SvnPath = string.IsNullOrWhiteSpace(SvnPathBox.Text) ? null : SvnPathBox.Text.Trim();
        settings.TimeoutSeconds = double.IsNaN(TimeoutBox.Value) ? 300 : (int)TimeoutBox.Value;
        settings.AutoPreviewUpdate = AutoPreviewToggle.IsOn;

        SaveButton.IsEnabled = false;
        SaveStatus.Text = "正在重新连接…";
        try
        {
            var installation = await _viewModel.SaveSettingsAsync(settings);
            SaveStatus.Text = $"已保存；当前 svn {installation.Version}。";
            RefreshInstallationText();
        }
        catch (OpenSVNException exception)
        {
            SaveStatus.Text = $"{exception.Identifier} {exception.Message}" +
                              (string.IsNullOrWhiteSpace(exception.Remediation)
                                  ? ""
                                  : "\n" + exception.Remediation);
            _viewModel.Notify(NotificationSeverity.Error, "设置未保存",
                SaveStatus.Text);
        }
        catch (Exception exception)
        {
            SaveStatus.Text = exception.Message;
        }
        finally
        {
            SaveButton.IsEnabled = true;
        }
    }

    private async void RefreshCredentials_Click(object sender, RoutedEventArgs e) =>
        await RefreshCredentialsAsync();

    private async Task RefreshCredentialsAsync()
    {
        _clearArmed = false;
        ClearCredentialsButton.Content = "清除全部";
        CredentialHint.Visibility = Visibility.Collapsed;
        var scopes = await _viewModel.GetCredentialScopesAsync();
        if (scopes is null)
        {
            // Keep the last list on screen: an unreadable store is not the same
            // as "no saved credentials".
            CredentialHint.Text = "无法读取已保存的凭据，请查看上方错误提示。";
            CredentialHint.Visibility = Visibility.Visible;
            NoCredentialsText.Visibility = Visibility.Collapsed;
            return;
        }
        _scopes.Clear();
        foreach (var scope in scopes.OrderBy(scope => scope.Host, StringComparer.OrdinalIgnoreCase))
        {
            _scopes.Add(scope);
        }
        NoCredentialsText.Visibility = _scopes.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void DeleteCredential_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string storageKey }) return;
        var scope = _scopes.FirstOrDefault(item => item.StorageKey == storageKey);
        if (scope is null) return;
        await _viewModel.ForgetCredentialAsync(scope);
        await RefreshCredentialsAsync();
    }

    private async void ClearCredentials_Click(object sender, RoutedEventArgs e)
    {
        if (!_clearArmed)
        {
            _clearArmed = true;
            ClearCredentialsButton.Content = "再次点击确认";
            CredentialHint.Text = "清除后，下次访问仓库需要重新输入密码。再次点击「再次点击确认」继续。";
            CredentialHint.Visibility = Visibility.Visible;
            return;
        }

        _clearArmed = false;
        ClearCredentialsButton.Content = "清除全部";
        CredentialHint.Visibility = Visibility.Collapsed;
        await _viewModel.ForgetAllCredentialsAsync();
        await RefreshCredentialsAsync();
    }

    private void OpenDataDirectory_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(AppSettings.DataDirectory);
            Process.Start(new ProcessStartInfo
            {
                FileName = AppSettings.DataDirectory,
                UseShellExecute = true,
            });
        }
        catch (Exception exception)
        {
            _viewModel.Notify(NotificationSeverity.Error, "无法打开数据目录", exception.Message);
        }
    }

    private async void Journal_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new JournalDialog(_viewModel);
        await DialogCoordinator.ShowAsync(dialog, XamlRoot);
    }
}
