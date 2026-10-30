using System.Runtime.InteropServices;

namespace Folio.Core;

/// <summary>The C API of the engine (src/ffi.rs, macos/Sources/CFolio/include/folio.h): UTF-8 strings in,
/// a heap string out that <c>folio_free</c> releases. Only what the Windows client uses.</summary>
internal static class Native
{
    const string Lib = "folio";

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr folio_anchor(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemsJson,
        [MarshalAs(UnmanagedType.U1)] bool raw);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr folio_accept(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string sidecarJson,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string id);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr folio_edit(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string sidecarJson,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string editJson);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr folio_sidecar_path([MarshalAs(UnmanagedType.LPUTF8Str)] string file);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void folio_free(IntPtr ptr);
}
