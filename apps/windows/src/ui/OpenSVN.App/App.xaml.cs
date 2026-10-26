using Microsoft.UI.Xaml;
using OpenSVN.App.Services;
using OpenSVN.App.ViewModels;

namespace OpenSVN.App;

public partial class App : Application
{
    public static MainWindow? MainWindow { get; set; }
    public static MainViewModel? ViewModel { get; set; }

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, args) =>
        {
            try
            {
                var directory = AppSettings.DataDirectory;
                Directory.CreateDirectory(directory);
                File.AppendAllText(Path.Combine(directory, "crash.log"),
                    $"[{DateTimeOffset.Now:O}] {args.Exception}\n");
            }
            catch
            {
                // A crash log must never replace the original failure.
            }
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        MainWindow = new MainWindow();
        MainWindow.Activate();
    }
}
