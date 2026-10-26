using Microsoft.UI.Xaml.Controls;
using OpenSVN.App.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace OpenSVN.App.Dialogs;

public sealed partial class DiffDialog : ContentDialog
{
    private readonly string _text;

    public DiffDialog(string title, string text, bool truncated = false, long byteCount = 0)
    {
        InitializeComponent();
        Title = title;
        _text = text ?? "";
        var lineCount = _text.Length == 0 ? 0 : _text.Count(character => character == '\n') + 1;
        SummaryText.Text = _text.Length == 0
            ? "没有可显示的差异。"
            : $"{lineCount:N0} 行 · {byteCount:N0} 字节" +
              (truncated ? " · 已按大小截断" : "");
        Diff.SetText(_text, truncated, byteCount);
        SecondaryButtonClick += OnCopy;
    }

    private void OnCopy(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var package = new DataPackage();
        package.SetText(_text);
        Clipboard.SetContent(package);
    }
}
