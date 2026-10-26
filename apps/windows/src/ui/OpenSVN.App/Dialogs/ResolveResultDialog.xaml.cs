using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenSVN.App.Models;
using System.Diagnostics;
using System.Linq;

namespace OpenSVN.App.Dialogs;

public sealed partial class ResolveResultDialog : ContentDialog
{
    private readonly ResolveOutcomeDto _outcome;

    public ResolveResultDialog(ResolveOutcomeDto outcome)
    {
        InitializeComponent();
        _outcome = outcome;
        var residualCount = outcome.ResidualMarkers.Count;
        Title = residualCount > 0
            ? $"已标记为已解决，但仍有 {residualCount} 个文件含冲突标记"
            : "冲突已解决";

        SummaryText.Text = $"已解决 {outcome.ResolvedPaths.Count} 个路径。" +
                           (outcome.Backup is null
                               ? "本次没有创建备份。"
                               : $"备份中有 {outcome.Backup.Files.Count} 个文件。");

        if (outcome.Backup is not null && !string.IsNullOrWhiteSpace(outcome.Backup.Directory))
        {
            BackupPanel.Visibility = Visibility.Visible;
            BackupPath.Text = outcome.Backup.Directory;
            SecondaryButtonText = "打开备份位置";
            SecondaryButtonClick += (_, _) => OpenFolder(outcome.Backup.Directory);
        }

        if (residualCount > 0)
        {
            ResidualPanel.Visibility = Visibility.Visible;
            ResidualTitle.Text = $"以下文件仍含冲突标记：{residualCount} 个";
            foreach (var path in outcome.ResidualMarkers)
            {
                var scan = outcome.Scans.FirstOrDefault(item => item.Path == path);
                var lines = scan is { MarkerLines.Count: > 0 }
                    ? "（第 " + string.Join("、", scan.MarkerLines.Take(12)) +
                      (scan.MarkerLines.Count > 12 ? "…" : "") + " 行）"
                    : "";
                ResidualList.Children.Add(new TextBlock
                {
                    Text = "· " + path + lines,
                    TextWrapping = TextWrapping.Wrap,
                    FontSize = 12,
                });
            }
        }

        var skipped = outcome.Scans.Where(scan => scan.Skipped).ToList();
        if (skipped.Count > 0)
        {
            SkippedText.Visibility = Visibility.Visible;
            SkippedText.Text = $"有 {skipped.Count} 个文件未检查冲突标记：" +
                               string.Join("、", skipped.Select(scan =>
                                   scan.Path + (string.IsNullOrWhiteSpace(scan.SkipReason)
                                       ? ""
                                       : $"（{scan.SkipReason}）")));
        }
    }

    private static void OpenFolder(string directory)
    {
        try
        {
            Process.Start(new ProcessStartInfo { FileName = directory, UseShellExecute = true });
        }
        catch
        {
            // The path is displayed and selectable; opening it is a convenience.
        }
    }
}
