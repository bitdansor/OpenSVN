using OpenSVN.App.Models;
using OpenSVN.App.Native;
using OpenSVN.App.Services;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenSVN.App.Native;

public sealed class SVNCredential
{
    public SVNCredential(string username, string password)
    {
        Username = username;
        Password = password;
    }

    public string Username { get; }
    public string Password { get; }
}

public sealed class OkDto
{
    public bool Ok { get; set; }
}

public sealed class OpenSVNClient : IDisposable
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        NumberHandling = System.Text.Json.Serialization.JsonNumberHandling.AllowReadingFromString,
    };

    private readonly object _lifecycle = new();
    private IntPtr _service;
    private long _requestId;
    private int _activeCalls;
    private bool _disposeRequested;

    private OpenSVNClient(IntPtr service, AppSettings settings)
    {
        _service = service;
        Settings = settings;
    }

    public AppSettings Settings { get; }

    public static Task<OpenSVNClient> CreateAsync(AppSettings settings) =>
        Task.Run(() => Create(settings));

    public static OpenSVNClient Create(AppSettings settings)
    {
        Directory.CreateDirectory(AppSettings.DataDirectory);
        var config = new JsonObject
        {
            ["timeoutSeconds"] = Math.Clamp(settings.TimeoutSeconds, 5, 3600),
            ["maxConcurrentWrites"] = Math.Clamp(settings.MaxConcurrentWrites, 1, 32),
            ["journalDirectory"] = AppSettings.DataDirectory,
            ["conflictBackupRoot"] = Path.Combine(AppSettings.DataDirectory, "ConflictBackups"),
            ["inMemoryCredentials"] = false,
        };
        if (!string.IsNullOrWhiteSpace(settings.SvnPath))
        {
            config["svnPath"] = settings.SvnPath;
        }

        IntPtr service = IntPtr.Zero;
        IntPtr error = IntPtr.Zero;
        try
        {
            var created = NativeMethods.opensvn_create_service(config.ToJsonString(), out service, out error);
            if (created == 0)
            {
                throw ParseNativeError(error);
            }
        }
        catch (DllNotFoundException exception)
        {
            throw new OpenSVNException("SVN-9998",
                "找不到 OpenSVN.Native.dll。请先构建 C++ 核心，再启动应用。",
                exception.Message, null, "fatal", "运行 scripts/build-windows.ps1。", false, false);
        }
        catch (BadImageFormatException exception)
        {
            throw new OpenSVNException("SVN-9998",
                "OpenSVN.Native.dll 的位数与应用不匹配。", exception.Message, null, "fatal",
                "使用 x64 构建。", false, false);
        }
        finally
        {
            if (error != IntPtr.Zero) NativeMethods.opensvn_free_string(error);
        }

        return new OpenSVNClient(service, settings);
    }

    public async Task<InstallationDto> GetInstallationAsync(CancellationToken cancellationToken = default) =>
        await InvokeAsync<InstallationDto>("installation", null, null, cancellationToken)
            .ConfigureAwait(false);

    public async Task<T> InvokeAsync<T>(
        string operation,
        object? parameters,
        IProgress<string>? progress = null,
        CancellationToken cancellationToken = default,
        SVNCredential? credential = null) where T : class
    {
        var result = await Task.Run(() => Invoke<T>(operation, parameters, progress,
            cancellationToken, credential)).ConfigureAwait(false);
        return result ?? throw new OpenSVNException("SVN-9998", "原生层返回了空结果",
            null, null, "fatal", null, false, false);
    }

    public async Task<T?> InvokeNullableAsync<T>(
        string operation,
        object? parameters,
        IProgress<string>? progress = null,
        CancellationToken cancellationToken = default,
        SVNCredential? credential = null) where T : class
    {
        return await Task.Run(() => Invoke<T>(operation, parameters, progress, cancellationToken, credential))
            .ConfigureAwait(false);
    }

    private T? Invoke<T>(
        string operation,
        object? parameters,
        IProgress<string>? progress,
        CancellationToken cancellationToken,
        SVNCredential? credential) where T : class
    {
        cancellationToken.ThrowIfCancellationRequested();
        EnterCall();
        GCHandle progressHandle = default;
        IntPtr result = IntPtr.Zero;
        IntPtr error = IntPtr.Zero;
        var requestId = nextRequestId();
        using var registration = cancellationToken.Register(
            static state =>
            {
                var (client, id) = ((OpenSVNClient, ulong))state!;
                client.Cancel(id);
            }, (this, requestId));

        try
        {
            JsonObject payload;
            if (parameters is JsonObject existing)
            {
                payload = (JsonObject)existing.DeepClone();
            }
            else if (parameters is null)
            {
                payload = new JsonObject();
            }
            else
            {
                payload = JsonSerializer.SerializeToNode(parameters) as JsonObject ?? new JsonObject();
            }

            if (credential is not null)
            {
                payload["credential"] = new JsonObject
                {
                    ["username"] = credential.Username,
                    ["password"] = credential.Password,
                };
            }

            NativeMethods.ProgressCallback? callback = null;
            if (progress is not null)
            {
                progressHandle = GCHandle.Alloc(progress);
                var userData = GCHandle.ToIntPtr(progressHandle);
                callback = (line, user) =>
                {
                    try
                    {
                        if (line == IntPtr.Zero) return;
                        var text = Marshal.PtrToStringUTF8(line);
                        if (text is null) return;
                        var target = GCHandle.FromIntPtr(user).Target as IProgress<string>;
                        target?.Report(text);
                    }
                    catch
                    {
                        // Never let a UI callback unwind into native code.
                    }
                };
            }

            result = NativeMethods.opensvn_invoke(_service, requestId, operation,
                payload.ToJsonString(), callback, progressHandle.IsAllocated ? GCHandle.ToIntPtr(progressHandle) : IntPtr.Zero,
                out error);

            if (error != IntPtr.Zero)
            {
                throw ParseNativeError(error);
            }
            if (result == IntPtr.Zero)
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    throw new OperationCanceledException(cancellationToken);
                }
                throw new OpenSVNException("SVN-9998", "原生层没有返回结果", null, null,
                    "fatal", null, false, false);
            }

            var json = Marshal.PtrToStringUTF8(result) ?? "null";
            return JsonSerializer.Deserialize<T>(json, SerializerOptions);
        }
        finally
        {
            if (result != IntPtr.Zero) NativeMethods.opensvn_free_string(result);
            if (error != IntPtr.Zero) NativeMethods.opensvn_free_string(error);
            if (progressHandle.IsAllocated) progressHandle.Free();
            ExitCall();
        }

        ulong nextRequestId() => (ulong)Interlocked.Increment(ref _requestId);
    }

    private void Cancel(ulong requestId)
    {
        // Hold the lifecycle lock across the native call: ExitCall may destroy
        // the service as soon as the last active call returns, and a freed
        // handle must never be passed to opensvn_cancel.
        lock (_lifecycle)
        {
            if (_service != IntPtr.Zero)
            {
                NativeMethods.opensvn_cancel(_service, requestId);
            }
        }
    }

    private void EnterCall()
    {
        lock (_lifecycle)
        {
            if (_disposeRequested) throw new ObjectDisposedException(nameof(OpenSVNClient));
            _activeCalls++;
        }
    }

    private void ExitCall()
    {
        IntPtr service = IntPtr.Zero;
        lock (_lifecycle)
        {
            _activeCalls--;
            if (_disposeRequested && _activeCalls == 0 && _service != IntPtr.Zero)
            {
                service = _service;
                _service = IntPtr.Zero;
            }
        }
        if (service != IntPtr.Zero) NativeMethods.opensvn_destroy_service(service);
    }

    private static OpenSVNException ParseNativeError(IntPtr error)
    {
        if (error == IntPtr.Zero)
        {
            return new OpenSVNException("SVN-9998", "原生层返回了未知错误", null, null,
                "fatal", null, false, false);
        }
        var json = Marshal.PtrToStringUTF8(error) ?? "";
        return OpenSVNException.FromJson(json);
    }

    public void Dispose()
    {
        IntPtr service = IntPtr.Zero;
        lock (_lifecycle)
        {
            _disposeRequested = true;
            if (_activeCalls == 0 && _service != IntPtr.Zero)
            {
                service = _service;
                _service = IntPtr.Zero;
            }
        }
        if (service != IntPtr.Zero) NativeMethods.opensvn_destroy_service(service);
    }
}
