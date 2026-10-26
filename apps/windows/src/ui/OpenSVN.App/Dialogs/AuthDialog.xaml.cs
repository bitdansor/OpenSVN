using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace OpenSVN.App.Dialogs;

public sealed partial class AuthDialog : ContentDialog
{
    public AuthDialog(string host, string? repositoryUrl)
    {
        InitializeComponent();
        HostText.Text = host;
        UrlText.Text = string.IsNullOrWhiteSpace(repositoryUrl) ? "" : repositoryUrl;
        Opened += (_, _) => UsernameBox.Focus(FocusState.Programmatic);
        PrimaryButtonClick += OnPrimary;
    }

    public string Username => UsernameBox.Text.Trim();
    public string Password => PasswordBox.Password;

    private void OnPrimary(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        if (Username.Length == 0)
        {
            ErrorText.Text = "用户名不能为空。";
            ErrorText.Visibility = Visibility.Visible;
            args.Cancel = true;
        }
    }
}
