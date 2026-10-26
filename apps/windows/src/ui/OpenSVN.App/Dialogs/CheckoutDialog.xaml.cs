using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace OpenSVN.App.Dialogs;

public sealed partial class CheckoutDialog : ContentDialog
{
    public CheckoutDialog()
    {
        InitializeComponent();
        Opened += (_, _) => UrlBox.Focus(FocusState.Programmatic);
        PrimaryButtonClick += OnPrimary;
    }

    public string RepositoryUrl => UrlBox.Text.Trim();
    public string Destination => DestinationBox.Text.Trim();
    public string Depth =>
        (DepthBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "infinity";

    public long? Revision
    {
        get
        {
            var text = RevisionBox.Text.Trim();
            return long.TryParse(text, out var revision) && revision > 0 ? revision : null;
        }
    }

    private async void Browse_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker,
            WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow!));
        var folder = await picker.PickSingleFolderAsync();
        if (folder is not null) DestinationBox.Text = folder.Path;
    }

    private void OnPrimary(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        if (!Uri.TryCreate(RepositoryUrl, UriKind.Absolute, out var uri) ||
            uri.Scheme is not ("http" or "https" or "svn" or "svn+ssh" or "file"))
        {
            ShowError("请输入有效的仓库 URL（http、https、svn、svn+ssh 或 file）。");
            args.Cancel = true;
            return;
        }
        if (Destination.Length == 0)
        {
            ShowError("请选择目标目录。");
            args.Cancel = true;
            return;
        }
        if (!string.IsNullOrWhiteSpace(RevisionBox.Text) && Revision is null)
        {
            ShowError("修订号必须是正整数，或留空使用最新修订。");
            args.Cancel = true;
        }
    }

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
    }
}
