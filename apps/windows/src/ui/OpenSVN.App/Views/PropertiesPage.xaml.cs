using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenSVN.App.Models;
using OpenSVN.App.ViewModels;
using System.IO;
using System.Linq;

namespace OpenSVN.App.Views;

public sealed class PropertyRow
{
    public required string TargetPath { get; init; }
    public required string Name { get; init; }
    public required string Value { get; init; }
    public required string DisplayPath { get; init; }

    public bool IsReserved => Name.StartsWith("svn:", StringComparison.OrdinalIgnoreCase);
    public Visibility ReservedVisibility => IsReserved ? Visibility.Visible : Visibility.Collapsed;
    public string ValuePreview
    {
        get
        {
            var text = Value.Replace("\r", "").Replace('\n', ' ').Trim();
            if (text.Length == 0) return "（空值）";
            return text.Length <= 120 ? text : text[..120] + "…";
        }
    }
}

public sealed partial class PropertiesPage : Page
{
    private readonly List<PropertyRow> _rows = new();
    private string _target = "";
    private bool _loaded;
    private int _loadVersion;

    public PropertiesPage()
    {
        InitializeComponent();
        PropertyList.ItemsSource = _rows;
    }

    public MainViewModel ViewModel => App.ViewModel!;

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _target = !string.IsNullOrWhiteSpace(ViewModel.PropertiesTarget)
            ? ViewModel.PropertiesTarget
            : ViewModel.WorkingCopyPath;
        TargetText.Text = Relative(_target);
        _loaded = true;
        await ReloadAsync();
    }

    private string Relative(string path)
    {
        try
        {
            var root = ViewModel.WorkingCopyPath;
            var relative = Path.GetRelativePath(root, path);
            return relative == "." ? new DirectoryInfo(root).Name : relative;
        }
        catch
        {
            return path;
        }
    }

    private async Task ReloadAsync(string? selectName = null, string? selectTarget = null)
    {
        if (!ViewModel.HasWorkingCopy) return;
        var selectedName = selectName ?? (PropertyList.SelectedItem as PropertyRow)?.Name;
        var selectedTarget = selectTarget ?? (PropertyList.SelectedItem as PropertyRow)?.TargetPath;
        var targetPath = _target;
        var version = ++_loadVersion;
        LoadingRing.IsActive = true;
        try
        {
            var targets = await ViewModel.LoadPropertiesAsync(targetPath, RecursiveCheck.IsChecked == true);
            if (version != _loadVersion || !string.Equals(targetPath, _target, StringComparison.Ordinal)) return;
            if (targets is null) return;

            _rows.Clear();
            foreach (var target in targets)
            {
                foreach (var property in target.Properties)
                {
                    _rows.Add(new PropertyRow
                    {
                        TargetPath = target.Path,
                        Name = property.Name,
                        Value = property.Value,
                        DisplayPath = Relative(target.Path),
                    });
                }
            }

            PropertyList.ItemsSource = null;
            PropertyList.ItemsSource = _rows;
            PropertyList.SelectedItem = _rows.FirstOrDefault(row =>
                row.Name == selectedName &&
                (selectedTarget is null || row.TargetPath == selectedTarget));
            EmptyState.Visibility = _rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        finally
        {
            if (version == _loadVersion) LoadingRing.IsActive = false;
        }
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await ReloadAsync();

    private async void Recursive_Changed(object sender, RoutedEventArgs e)
    {
        if (_loaded) await ReloadAsync();
    }

    private void PropertyList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (PropertyList.SelectedItem is not PropertyRow row)
        {
            DeleteButton.IsEnabled = false;
            return;
        }

        NameBox.Text = row.Name;
        NameBox.IsReadOnly = true;
        ValueBox.Text = row.Value;
        DeleteButton.IsEnabled = true;
        EditorStatus.Text = $"编辑「{row.Name}」，应用于 {row.DisplayPath}";
    }

    private void New_Click(object sender, RoutedEventArgs e)
    {
        PropertyList.SelectedItem = null;
        NameBox.IsReadOnly = false;
        NameBox.Text = "";
        ValueBox.Text = "";
        DeleteButton.IsEnabled = false;
        EditorStatus.Text = $"新属性将应用到 {Relative(_target)}";
        NameBox.Focus(FocusState.Programmatic);
    }

    private async void Apply_Click(object sender, RoutedEventArgs e)
    {
        var name = NameBox.Text.Trim();
        if (name.Length == 0)
        {
            EditorStatus.Text = "属性名不能为空。";
            return;
        }

        var selected = PropertyList.SelectedItem as PropertyRow;
        var target = selected?.TargetPath ?? _target;
        ApplyButton.IsEnabled = false;
        try
        {
            var value = ValueBox.Text.Replace("\r\n", "\n");
            EditorStatus.Text = "正在应用…";
            var applied = await ViewModel.SetPropertyAsync(name, value, new[] { target });
            if (applied)
            {
                EditorStatus.Text = $"已应用 {name}。";
                await ReloadAsync(name, target);
            }
            else
            {
                EditorStatus.Text = "属性未应用，请查看上方错误提示。";
            }
        }
        finally
        {
            ApplyButton.IsEnabled = true;
        }
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (PropertyList.SelectedItem is not PropertyRow row) return;
        DeleteButton.IsEnabled = false;
        try
        {
            var deleted = await ViewModel.DeletePropertyAsync(row.Name, new[] { row.TargetPath });
            if (deleted)
            {
                New_Click(sender, e);
                await ReloadAsync();
            }
        }
        finally
        {
            DeleteButton.IsEnabled = PropertyList.SelectedItem is PropertyRow;
        }
    }
}
