using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Runtime.InteropServices;

namespace OpenSVN.App.Services;

/// <summary>
/// WinUI allows one ContentDialog at a time. Page dialogs and shell dialogs
/// therefore share one gate instead of each keeping its own boolean.
/// </summary>
public static class DialogCoordinator
{
    private static readonly SemaphoreSlim Gate = new(1, 1);

    public static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog, XamlRoot? root)
    {
        if (root is null) return ContentDialogResult.None;
        if (!await Gate.WaitAsync(TimeSpan.FromSeconds(5))) return ContentDialogResult.None;
        try
        {
            dialog.XamlRoot = root;
            return await dialog.ShowAsync();
        }
        catch (COMException)
        {
            return ContentDialogResult.None;
        }
        finally
        {
            Gate.Release();
        }
    }
}
