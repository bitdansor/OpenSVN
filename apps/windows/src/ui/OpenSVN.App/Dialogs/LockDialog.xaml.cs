using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace OpenSVN.App.Dialogs;

public sealed partial class LockDialog : ContentDialog
{
    public LockDialog(int pathCount)
    {
        InitializeComponent();
        SummaryText.Text = $"将为 {pathCount} 个路径申请仓库锁。锁定只登记独占编辑权，不修改文件内容。";
    }

    public string? Comment =>
        string.IsNullOrWhiteSpace(CommentBox.Text) ? null : CommentBox.Text.Trim();

    public bool Steal => StealCheck.IsChecked == true;

    private void Steal_Changed(object sender, RoutedEventArgs e)
    {
        StealWarning.Visibility = Steal ? Visibility.Visible : Visibility.Collapsed;
        PrimaryButtonText = Steal ? "强制锁定" : "锁定";
    }
}
