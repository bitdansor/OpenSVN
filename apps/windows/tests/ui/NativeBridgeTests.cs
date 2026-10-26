using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using OpenSVN.App.Native;
using OpenSVN.App.Services;

namespace OpenSVN.App.Tests;

/// <summary>
/// Exercises the managed/native request handshake against the real C ABI and
/// the fake svn used by the native suite. Runs only from the build script,
/// which builds the native bridge first.
/// </summary>
internal static class NativeBridgeChecks
{
    public static async Task<int> RunAsync()
    {
        var failures = new List<string>();
        var root = FindRepositoryRoot();
        if (root is null)
        {
            Console.Error.WriteLine("FAIL: cannot locate apps/windows/build from the test output");
            return 1;
        }

        var nativePath = Environment.GetEnvironmentVariable("OPENSVN_NATIVE_DLL") ??
                         FindBuildFile(root, "OpenSVN.Native.dll");
        var fakeSvn = Environment.GetEnvironmentVariable("OPENSVN_FAKE_SVN") ??
                      (nativePath is null ? null : Path.Combine(Path.GetDirectoryName(nativePath)!, "fake_svn.exe"));
        if (nativePath is null || fakeSvn is null || !File.Exists(nativePath) || !File.Exists(fakeSvn))
        {
            Console.Error.WriteLine("FAIL: native DLL or fake_svn.exe is missing; run the native build first");
            return 1;
        }

        NativeLibrary.SetDllImportResolver(typeof(OpenSVNClient).Assembly,
            (name, _, _) => string.Equals(name, "OpenSVN.Native.dll", StringComparison.OrdinalIgnoreCase)
                ? NativeLibrary.Load(nativePath)
                : IntPtr.Zero);

        var settings = new AppSettings { SvnPath = fakeSvn, TimeoutSeconds = 10 };
        await CheckAsync(failures, "empty operation", settings, async client =>
        {
            var error = await CaptureAsync(() => client.InvokeAsync<JsonObject>("", null));
            if (error is not OpenSVNException { Identifier: "SVN-9001" })
            {
                failures.Add("empty operation: expected SVN-9001, got " +
                             Describe(error));
            }
        });

        await CheckAsync(failures, "serialization failure", settings, async client =>
        {
            for (var attempt = 0; attempt < 3; ++attempt)
            {
                var error = await CaptureAsync(() =>
                    client.InvokeAsync<JsonObject>("status", new ThrowingParameters()));
                if (error is null) failures.Add("serialization failure: expected an error");
            }
        });

        await CheckAsync(failures, "cancellation during serialization", settings, async client =>
        {
            using var cancellation = new CancellationTokenSource();
            var error = await CaptureAsync(() => client.InvokeAsync<JsonObject>("delete",
                new CancelDuringSerialization(cancellation),
                cancellationToken: cancellation.Token));
            if (error is not OperationCanceledException &&
                error is not OpenSVNException { Cancelled: true })
            {
                failures.Add("cancellation during serialization: expected cancellation, got " +
                             Describe(error));
            }
        });

        try
        {
            Directory.Delete(AppSettings.DataDirectory, true);
        }
        catch
        {
            // A destroyed service may still hold journal files briefly.
        }

        if (failures.Count > 0)
        {
            foreach (var failure in failures) Console.Error.WriteLine("FAIL: " + failure);
        }
        else
        {
            Console.WriteLine("Managed native bridge tests passed.");
        }
        return failures.Count;
    }

    private static async Task CheckAsync(List<string> failures, string label,
        AppSettings settings, Func<OpenSVNClient, Task> scenario)
    {
        var client = await OpenSVNClient.CreateAsync(settings);
        try
        {
            await scenario(client);
        }
        catch (Exception error)
        {
            failures.Add($"{label}: unexpected {Describe(error)}");
        }

        var dispose = Task.Run(client.Dispose);
        if (await Task.WhenAny(dispose, Task.Delay(TimeSpan.FromSeconds(3))) != dispose)
        {
            failures.Add($"{label}: Dispose did not complete; a request registration leaked");
        }
    }

    private static async Task<Exception?> CaptureAsync(Func<Task> action)
    {
        try
        {
            await action();
            return null;
        }
        catch (Exception error)
        {
            return error;
        }
    }

    private static string Describe(Exception? error) =>
        error is null ? "no error" : $"{error.GetType().Name}: {error.Message}";

    private static string? FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (Directory.Exists(Path.Combine(directory.FullName, "apps", "windows", "build")))
            {
                return directory.FullName;
            }
            directory = directory.Parent;
        }
        return null;
    }

    private static string? FindBuildFile(string root, string name)
    {
        var output = new DirectoryInfo(AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar));
        var preferred = output.Parent?.Name ?? "Debug";
        foreach (var configuration in new[] { preferred, "Debug", "Release" })
        {
            var candidate = Path.Combine(root, "apps", "windows", "build", configuration, name);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    private sealed class ThrowingParameters
    {
        public string[] Paths => throw new InvalidOperationException("serialization intentionally failed");
    }

    private sealed class CancelDuringSerialization(CancellationTokenSource cancellation)
    {
        public string[] Paths
        {
            get
            {
                cancellation.Cancel();
                return ["unused.txt"];
            }
        }

        public bool Confirmed => true;
        public bool Force => true;
    }
}
