using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenSVN.App.Models;
using OpenSVN.App.ViewModels;
using System.Collections.ObjectModel;

namespace OpenSVN.App.Dialogs;

public sealed partial class JournalDialog : ContentDialog
{
    private readonly MainViewModel _viewModel;

    public JournalDialog(MainViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        Opened += async (_, _) => await LoadAsync();
        PrimaryButtonClick += OnDiscardAll;
    }

    public ObservableCollection<JournalEntryDto> Entries { get; } = new();

    private async Task LoadAsync()
    {
        await _viewModel.RefreshJournalAsync();
        var journal = _viewModel.Journal;
        Entries.Clear();
        if (journal is not null)
        {
            foreach (var entry in journal.Entries) Entries.Add(entry);
            var extras = new List<string>();
            if (!string.IsNullOrWhiteSpace(journal.Quarantined))
                extras.Add("损坏的操作日志已被隔离：" + journal.Quarantined);
            if (!string.IsNullOrWhiteSpace(journal.WriteFailure))
                extras.Add("写入操作日志失败：" + journal.WriteFailure);
            ExtraText.Text = string.Join("\n", extras);
            ExtraText.Visibility = extras.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        UpdateState();
    }

    private void UpdateState()
    {
        SummaryText.Text = Entries.Count == 0
            ? "没有待处理的记录。"
            : $"有 {Entries.Count} 个写操作没有记录结果。它们可能已经完成、部分完成或失败。";
        EmptyText.Visibility = Entries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        IsPrimaryButtonEnabled = Entries.Count > 0;
    }

    private async void OnDiscardAll(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true;
        IsPrimaryButtonEnabled = false;
        await _viewModel.DiscardAllJournalAsync();
        Entries.Clear();
        UpdateState();
        Hide();
    }

    private async void DiscardOne_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string id } button) return;
        button.IsEnabled = false;
        await _viewModel.DiscardJournalEntryAsync(id);
        var entry = Entries.FirstOrDefault(item => item.Id == id);
        if (entry is not null) Entries.Remove(entry);
        UpdateState();
    }
}
