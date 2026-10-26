using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Linq;

namespace OpenSVN.App.Dialogs;

public sealed partial class ResolveDialog : ContentDialog
{
    private static readonly string[] Strategies = { "working", "mine-full", "theirs-full", "base" };
    private int _strategyIndex;

    public ResolveDialog(IReadOnlyList<string> paths)
    {
        InitializeComponent();
        Title = paths.Count == 1 ? $"解决冲突：{paths[0]}" : $"解决 {paths.Count} 个冲突";
        var shown = paths.Take(8).ToList();
        PathsText.Text = string.Join("\n", shown) +
                         (paths.Count > shown.Count ? $"\n…以及另外 {paths.Count - shown.Count} 个" : "");
        UpdateButtonText();
    }

    public string Strategy => Strategies[Math.Clamp(_strategyIndex, 0, Strategies.Length - 1)];

    private void Strategy_Changed(object sender, RoutedEventArgs e)
    {
        if (sender is RadioButton { Tag: string tag } && int.TryParse(tag, out var index))
        {
            _strategyIndex = index;
            UpdateButtonText();
        }
    }

    private void UpdateButtonText() =>
        PrimaryButtonText = _strategyIndex == 0 ? "解决" : "确认解决（会丢弃内容）";
}
