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
    public static extern IntPtr folio_rendered_selection([MarshalAs(UnmanagedType.LPUTF8Str)] string doc, nuint from, nuint to);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr folio_set_names();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr folio_set_load([MarshalAs(UnmanagedType.LPUTF8Str)] string name);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int folio_mcp_serve();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.U1)]
    public static extern bool folio_mcp_allowed();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr folio_mcp_set_allowed([MarshalAs(UnmanagedType.U1)] bool on);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr folio_mcp_snippets([MarshalAs(UnmanagedType.LPUTF8Str)] string exe);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr folio_mcp_connect([MarshalAs(UnmanagedType.LPUTF8Str)] string client, [MarshalAs(UnmanagedType.LPUTF8Str)] string exe);

    /// <summary>Answers one request of the MCP server: a UTF-8 JSON line in, a UTF-8 JSON line out, allocated with the
    /// C runtime's <c>malloc</c> (the library frees it with <c>free</c>). Called on a thread of the library's.</summary>
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate IntPtr AppHandler(IntPtr request);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr folio_app_listen(AppHandler handler);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void folio_app_stop();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void folio_free(IntPtr ptr);
}
