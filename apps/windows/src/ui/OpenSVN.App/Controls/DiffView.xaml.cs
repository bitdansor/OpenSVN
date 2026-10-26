using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace OpenSVN.App.Controls;

public sealed partial class DiffView : UserControl
{
    private const int MaximumLines = 6000;
    private const int InitialBatch = 600;
    private const int BatchSize = 600;

    private sealed record Palette(
        SolidColorBrush Background, SolidColorBrush Normal, SolidColorBrush Added,
        SolidColorBrush Removed, SolidColorBrush Header, SolidColorBrush Muted);

    private static readonly Palette LightPalette = new(
        CreateBrush(255, 255, 255), CreateBrush(30, 30, 30), CreateBrush(46, 139, 87),
        CreateBrush(192, 57, 43), CreateBrush(40, 100, 170), CreateBrush(110, 110, 110));
    private static readonly Palette DarkPalette = new(
        CreateBrush(30, 30, 30), CreateBrush(220, 220, 220), CreateBrush(106, 153, 85),
        CreateBrush(244, 135, 113), CreateBrush(86, 156, 214), CreateBrush(160, 160, 160));

    private string[] _lines = Array.Empty<string>();
    private Paragraph? _paragraph;
    private int _shownLines;
    private bool _sourceTruncated;
    private bool _hasContent;
    private long _byteCount;

    private Palette Current =>
        ActualTheme == ElementTheme.Dark ||
        (ActualTheme == ElementTheme.Default &&
         Application.Current.RequestedTheme == ApplicationTheme.Dark)
            ? DarkPalette
            : LightPalette;

    public DiffView()
    {
        InitializeComponent();
        ApplyTheme();
        ActualThemeChanged += (_, _) => ApplyTheme();
    }

    public string Text { get; private set; } = "";

    public void SetText(string? text, bool truncated = false, long byteCount = 0)
    {
        Text = text ?? "";
        _sourceTruncated = truncated;
        _byteCount = byteCount;
        _hasContent = true;
        _lines = string.IsNullOrEmpty(Text)
            ? Array.Empty<string>()
            : Text.Replace("\r\n", "\n").Split('\n');
        _shownLines = 0;
        Block.Blocks.Clear();
        LoadMoreButton.Visibility = Visibility.Collapsed;

        if (_lines.Length == 0)
        {
            ShowEmpty();
            return;
        }

        _paragraph = new Paragraph();
        Block.Blocks.Add(_paragraph);
        AppendLines(InitialBatch);
    }

    private void ApplyTheme()
    {
        var palette = Current;
        Surface.Background = palette.Background;
        Block.Foreground = palette.Normal;
        if (_hasContent) Rebuild();
    }

    private void Rebuild()
    {
        Block.Blocks.Clear();
        _paragraph = null;
        if (_lines.Length == 0)
        {
            ShowEmpty();
            return;
        }

        var keep = Math.Max(_shownLines, InitialBatch);
        _paragraph = new Paragraph();
        Block.Blocks.Add(_paragraph);
        _shownLines = 0;
        AppendLines(keep);
    }

    private void ShowEmpty()
    {
        Block.Blocks.Clear();
        var empty = new Paragraph();
        empty.Inlines.Add(new Run { Text = "没有文本差异。", Foreground = Current.Muted });
        Block.Blocks.Add(empty);
    }

    private void AppendLines(int count)
    {
        if (_paragraph is null) return;
        var palette = Current;
        var limit = Math.Min(_lines.Length, MaximumLines);
        var target = Math.Min(limit, _shownLines + count);
        for (var index = _shownLines; index < target; index++)
        {
            if (_paragraph.Inlines.Count > 0) _paragraph.Inlines.Add(new LineBreak());
            var line = _lines[index];
            _paragraph.Inlines.Add(new Run
            {
                Text = line.Length == 0 ? " " : line,
                Foreground = ColorFor(line, palette),
            });
        }
        _shownLines = target;

        var remaining = limit - _shownLines;
        if (remaining > 0)
        {
            LoadMoreButton.Content = $"显示更多（剩余 {remaining:N0} 行）";
            LoadMoreButton.Visibility = Visibility.Visible;
            return;
        }

        LoadMoreButton.Visibility = Visibility.Collapsed;
        if (_sourceTruncated || _lines.Length > limit)
        {
            var note = new Paragraph();
            note.Inlines.Add(new Run
            {
                Text = $"\n…差异已截断（显示 {_shownLines} 行，原始约 {_byteCount:N0} 字节）。",
                Foreground = palette.Muted,
            });
            Block.Blocks.Add(note);
        }
    }

    private void LoadMore_Click(object sender, RoutedEventArgs e) => AppendLines(BatchSize);

    private static Brush ColorFor(string line, Palette palette)
    {
        if (line.StartsWith("+++", StringComparison.Ordinal) ||
            line.StartsWith("---", StringComparison.Ordinal) ||
            line.StartsWith("Index:", StringComparison.Ordinal))
        {
            return palette.Muted;
        }
        if (line.StartsWith("@@", StringComparison.Ordinal)) return palette.Header;
        if (line.StartsWith('+')) return palette.Added;
        if (line.StartsWith('-')) return palette.Removed;
        return palette.Normal;
    }

    private static SolidColorBrush CreateBrush(byte red, byte green, byte blue) =>
        new(Color.FromArgb(255, red, green, blue));
}
