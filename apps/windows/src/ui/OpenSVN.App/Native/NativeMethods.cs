using System.Runtime.InteropServices;

namespace OpenSVN.App.Native;

internal static class NativeMethods
{
    internal const string Library = "OpenSVN.Native.dll";

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void ProgressCallback(IntPtr lineUtf8, IntPtr userData);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int opensvn_create_service(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string configJson,
        out IntPtr service,
        out IntPtr errorJson);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern void opensvn_destroy_service(IntPtr service);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern IntPtr opensvn_invoke(
        IntPtr service,
        ulong requestId,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string operation,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string parametersJson,
        ProgressCallback? progress,
        IntPtr userData,
        out IntPtr errorJson);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern int opensvn_register_request(
        IntPtr service,
        ulong requestId,
        out IntPtr errorJson);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern void opensvn_release_request(IntPtr service, ulong requestId);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern void opensvn_cancel(IntPtr service, ulong requestId);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern void opensvn_free_string(IntPtr value);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    internal static extern IntPtr opensvn_capi_version();
}
