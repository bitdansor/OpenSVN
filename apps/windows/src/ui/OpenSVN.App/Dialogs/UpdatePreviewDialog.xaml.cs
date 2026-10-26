using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenSVN.App.Models;
using OpenSVN.App.Native;
using System.Linq;

namespace OpenSVN.App.Dialogs;

public sealed partial class UpdatePreviewDialog : ContentDialog
{
    public UpdatePreviewDialog(RemotePreviewDto? preview, OpenSVNException? error,
        int localChanges, bool hasConflicts)
    {
        InitializeComponent();

        if (error is not null || preview is null)
        {
            Title = "无法预览远端变更";
            SummaryText.Text = "远端预检失败；你仍然可以更新。";
            SubSummaryText.Text = $"本地未提交改动：{localChanges} 个；本地冲突：{(hasConflicts ? "有" : "无")}。";
            ErrorText.Text = error is null
                ? "没有获得远端预览。"
                : $"{error.Identifier} {error.Message}" +
                  (string.IsNullOrWhiteSpace(error.Remediation) ? "" : "\n" + error.Remediation);
            ErrorText.Visibility = Visibility.Visible;
            ChangesList.Visibility = Visibility.Collapsed;
            EmptyText.Visibility = Visibility.Collapsed;
            PrimaryButtonText = "仍然更新";
            return;
        }

        var changes = preview.Changes.ToList();
        if (preview.RootPropertyChange is not null) changes.Insert(0, preview.RootPropertyChange);
        var riskCount = changes.Count(change => change.ConflictsWithLocal);
        var revisionText = preview.ServerRevision is long serverRevision
            ? $"目标修订 r{serverRevision}"
            : "目标修订未知";
        SummaryText.Text = changes.Count == 0
            ? "已是最新"
            : $"{revisionText} · 远端变更 {changes.Count} 个路径";
        SubSummaryText.Text =
            $"本地未提交改动：{localChanges} 个 · 可能冲突：{riskCount} 个 · 本地冲突：{(hasConflicts ? "有" : "无")}" +
            (changes.Count == 0 ? "。仍然更新可以重新应用属性或处理混合修订。" : "");
        ChangesList.ItemsSource = changes;
        ChangesList.Visibility = changes.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        EmptyText.Visibility = changes.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        PrimaryButtonText = preview.ServerRevision is long target
            ? $"更新到 r{target}"
            : (changes.Count == 0 ? "仍然更新" : "更新");
    }
}
