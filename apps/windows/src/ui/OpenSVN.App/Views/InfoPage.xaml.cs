using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenSVN.App.Models;
using OpenSVN.App.ViewModels;
using System.Linq;

namespace OpenSVN.App.Views;

public sealed class InfoRow
{
    public required string Label { get; init; }
    public required string Value { get; init; }
}

public sealed partial class InfoPage : Page
{
    private readonly List<InfoRow> _rows = new();
    private int _loadVersion;

    public InfoPage()
    {
        InitializeComponent();
        InfoList.ItemsSource = _rows;
    }

    public MainViewModel ViewModel => App.ViewModel!;

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await LoadAsync();
    }

    private async Task LoadAsync()
    {
        var version = ++_loadVersion;
        ErrorBar.IsOpen = false;
        EmptyState.Visibility = Visibility.Collapsed;
        LoadingRing.IsActive = true;
        try
        {
            var report = await ViewModel.LoadInfoAsync();
            if (version != _loadVersion) return;
            if (report is null)
            {
                ErrorBar.Message = "无法读取工作副本信息。请确认路径可访问后重试。";
                ErrorBar.IsOpen = true;
                return;
            }

            var info = report.Entries.FirstOrDefault();
            _rows.Clear();
            if (info is not null)
            {
                _rows.Add(new InfoRow { Label = "URL", Value = info.Url });
                _rows.Add(new InfoRow { Label = "仓库根", Value = info.RepositoryRoot ?? "—" });
                _rows.Add(new InfoRow { Label = "仓库 UUID", Value = info.RepositoryUuid ?? "—" });
                _rows.Add(new InfoRow { Label = "本地修订", Value = info.Revision is long revision ? "r" + revision : "—" });
                _rows.Add(new InfoRow { Label = "类型", Value = info.Kind == "dir" ? "目录" : info.Kind == "file" ? "文件" : info.Kind });
                if (!string.IsNullOrWhiteSpace(info.Schedule))
                    _rows.Add(new InfoRow { Label = "调度", Value = info.Schedule! });
                if (!string.IsNullOrWhiteSpace(info.Depth))
                    _rows.Add(new InfoRow { Label = "深度", Value = info.Depth! });
                if (!string.IsNullOrWhiteSpace(info.WorkingCopyRoot))
                    _rows.Add(new InfoRow { Label = "工作副本根", Value = info.WorkingCopyRoot! });
                _rows.Add(new InfoRow
                {
                    Label = "最后修改",
                    Value = info.LastChangedRevision is long changed
                        ? $"r{changed} · {info.LastChangedAuthor ?? "（无作者）"} · {Display.FormatDate(info.LastChangedDate)}"
                        : "—",
                });

                if (info.RepositoryLock is not null)
                {
                    _rows.Add(new InfoRow
                    {
                        Label = "仓库锁",
                        Value = $"{info.RepositoryLock.Owner ?? "未知用户"} · {Display.FormatDate(info.RepositoryLock.CreatedAt)}" +
                                (string.IsNullOrWhiteSpace(info.RepositoryLock.Comment) ? "" : " · " + info.RepositoryLock.Comment),
                    });
                }
                if (!string.IsNullOrWhiteSpace(info.ConflictType))
                {
                    _rows.Add(new InfoRow { Label = "冲突", Value = $"{info.ConflictOperation} / {info.ConflictType}" });
                }
            }

            InfoList.ItemsSource = null;
            InfoList.ItemsSource = _rows;
            EmptyState.Visibility = _rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        finally
        {
            if (version == _loadVersion) LoadingRing.IsActive = false;
        }
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await LoadAsync();
}
