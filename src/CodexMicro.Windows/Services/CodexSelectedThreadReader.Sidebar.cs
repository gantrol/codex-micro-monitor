using System.Runtime.InteropServices;

namespace CodexMicro.Desktop.Services;

internal sealed partial class CodexSelectedThreadReader
{
    private readonly record struct SidebarRow(string Title, string? Identity);

    private static string? ReadSidebarIdentity(nint window, IElement element)
    {
        object? current = null;
        try
        {
            current = ReadDomNodeAtElement(window, element, out var point);

            for (var depth = 0; depth < 12 && current is ISimpleDomNode node; depth++)
            {
                var attributes = ReadAttributes(node);
                if (attributes.ContainsKey("data-app-action-sidebar-thread-row"))
                    return GetAncestor(WindowFromPoint(point), 2) == window
                        ? ResolveSidebarIdentity(attributes) : null;
                if (node.GetParentNode(out var parent) < 0) return null;
                Marshal.ReleaseComObject(current);
                current = parent;
            }
            return null;
        }
        catch (Exception error) when (error is COMException or InvalidCastException)
        {
            // Never fall back to a title when the semantic ID is unavailable.
            return null;
        }
        finally
        {
            if (current is not null) Marshal.ReleaseComObject(current);
        }
    }

    private static object? ReadDomNodeAtElement(nint window, IElement element, out ScreenPoint point)
    {
        point = default;
        object? accessible = null, result = null;
        try
        {
            // Read the MSAA object without moving the pointer or clicking. Chromium's
            // native UIA provider does not expose the LegacyIAccessible pattern.
            if (element.GetCurrentPropertyValue(30001) is not double[] { Length: 4 } bounds ||
                bounds.Any(value => !double.IsFinite(value)) || bounds[2] <= 0 || bounds[3] <= 0) return null;
            point = new((int)(bounds[0] + bounds[2] / 2), (int)(bounds[1] + bounds[3] / 2));
            if (GetAncestor(WindowFromPoint(point), 2) != window ||
                AccessibleObjectFromPoint(point, out accessible, out _) < 0 ||
                accessible is not IAccessibleServiceProvider provider) return null;
            var service = typeof(ISimpleDomNode).GUID;
            var iid = service;
            if (provider.QueryService(ref service, ref iid, out result) >= 0 && result is ISimpleDomNode)
            {
                var node = result;
                result = null;
                return node;
            }
            return null;
        }
        finally
        {
            if (result is not null) Marshal.ReleaseComObject(result);
            if (accessible is not null) Marshal.ReleaseComObject(accessible);
        }
    }

    private static Dictionary<string, string> ReadAttributes(ISimpleDomNode node)
    {
        const ushort capacity = 64;
        var names = new string[capacity];
        var namespaces = new short[capacity];
        var values = new string[capacity];
        var attributes = new Dictionary<string, string>(StringComparer.Ordinal);
        if (node.GetAttributes(capacity, names, namespaces, values, out var count) < 0 || count > capacity)
            return attributes;
        for (var index = 0; index < count; index++)
            if (names[index] is { Length: > 0 } name && values[index] is { } value)
                attributes[name] = value;
        return attributes;
    }

    internal static string? ResolveSidebarIdentity(IReadOnlyDictionary<string, string> attributes)
    {
        const string prefix = "data-app-action-sidebar-thread-";
        if (attributes.GetValueOrDefault("aria-current") != "page" ||
            attributes.GetValueOrDefault(prefix + "active") != "true" ||
            attributes.GetValueOrDefault(prefix + "kind") != "local" ||
            attributes.GetValueOrDefault(prefix + "host-id") != "local" ||
            attributes.GetValueOrDefault(prefix + "id") is not { } key ||
            !key.StartsWith("local:", StringComparison.Ordinal)) return null;
        // The sidebar retains local:client-new-thread:<UUID> after creation.
        // Its UUID is a frontend identity, not an app-server thread ID.
        var identity = key[6..];
        return Guid.TryParseExact(identity, "D", out var threadId) ? threadId.ToString("D") :
            CodexDesktopRouteReader.IsClientThreadId(identity) ? identity : null;
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct ScreenPoint(int X, int Y);

    [DllImport("oleacc.dll")]
    private static extern int AccessibleObjectFromPoint(ScreenPoint point,
        [MarshalAs(UnmanagedType.Interface)] out object? accessible,
        [MarshalAs(UnmanagedType.Struct)] out object child);

    [DllImport("user32.dll")]
    private static extern nint WindowFromPoint(ScreenPoint point);

    [DllImport("user32.dll")]
    private static extern nint GetAncestor(nint window, uint flags);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(nint window, out uint processId);

    [ComImport, Guid("6d5140c1-7436-11ce-8034-00aa006009fa"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAccessibleServiceProvider
    {
        [PreserveSig]
        int QueryService(ref Guid service, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object? result);
    }

    [ComImport, Guid("1814ceeb-49e2-407f-af99-fa755a7d2607"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISimpleDomNode
    {
        void GetNodeInfo();
        [PreserveSig]
        int GetAttributes(ushort capacity,
            [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.BStr, SizeParamIndex = 0)] string[] names,
            [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] short[] namespaces,
            [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.BStr, SizeParamIndex = 0)] string[] values,
            out ushort count);
        void Slot2(); void Slot3(); void Slot4(); void Slot5();
        [PreserveSig]
        int GetParentNode([MarshalAs(UnmanagedType.Interface)] out object? parent);
        [PreserveSig]
        int GetFirstChild([MarshalAs(UnmanagedType.Interface)] out object? child);
        void Slot8(); void Slot9();
        [PreserveSig]
        int GetNextSibling([MarshalAs(UnmanagedType.Interface)] out object? sibling);
    }
}
