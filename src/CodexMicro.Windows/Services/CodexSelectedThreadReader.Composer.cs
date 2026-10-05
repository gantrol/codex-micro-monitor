using System.Runtime.InteropServices;

namespace CodexMicro.Desktop.Services;

internal sealed partial class CodexSelectedThreadReader
{
    private CodexThreadSelection? ReadComposerSelection(nint window, CancellationToken token)
    {
        IAutomation? client = null;
        IElement? root = null, editor = null;
        ICondition? condition = null;
        IElements? editors = null;
        try
        {
            client = (IAutomation)Activator.CreateInstance(Type.GetTypeFromCLSID(
                new Guid("ff48dba4-60ef-4201-aa87-54103eef594e"))!)!;
            root = client.ElementFromHandle(window);
            condition = client.CreatePropertyConditionEx(30012, "ProseMirror", 2);
            editors = root.FindAll(4, condition);
            for (var index = 0; index < editors.Length; index++)
            {
                token.ThrowIfCancellationRequested();
                IElement? candidate = editors.GetElement(index);
                try
                {
                    if (candidate.GetCurrentPropertyValue(30022) is not false ||
                        candidate.GetCurrentPropertyValue(30012) is not string css ||
                        !css.Split(' ').Contains("ProseMirror", StringComparer.Ordinal)) continue;
                    // More than one visible editor cannot authorize a single current chat.
                    if (editor is not null) return new(null, null, CanRetainThreadId: false);
                    editor = candidate;
                    candidate = null;
                }
                finally { if (candidate is not null) Marshal.ReleaseComObject(candidate); }
            }
            return editor is null ? null : ReadComposerSelection(window, editor, token);
        }
        finally
        {
            if (editor is not null) Marshal.ReleaseComObject(editor);
            if (editors is not null) Marshal.ReleaseComObject(editors);
            if (condition is not null) Marshal.ReleaseComObject(condition);
            if (root is not null) Marshal.ReleaseComObject(root);
            if (client is not null) Marshal.ReleaseComObject(client);
        }
    }

    private CodexThreadSelection? ReadComposerSelection(nint window, IElement editor, CancellationToken token)
    {
        object? current = null;
        try
        {
            current = ReadDomNodeAtElement(window, editor, out var point);
            var editorObserved = false;
            for (var depth = 0; depth < 16 && current is ISimpleDomNode node; depth++)
            {
                token.ThrowIfCancellationRequested();
                var attributes = ReadAttributes(node);
                editorObserved |= attributes.GetValueOrDefault("class")?.Split(' ')
                    .Contains("ProseMirror", StringComparer.Ordinal) == true;
                if (attributes.ContainsKey("data-codex-composer-root"))
                {
                    if (!editorObserved || attributes.GetValueOrDefault("data-composer-placement") != "thread")
                        return null;
                    var portal = ReadComposerPortal(node, token);
                    if (portal is null || GetAncestor(WindowFromPoint(point), 2) != window) return null;
                    var identity = portal.GetValueOrDefault("data-above-composer-conversation-id");
                    // The Codex composer emits conversationId here, not its retained
                    // clientThreadId. ChatGPT and remote hosts must not become local IPC targets.
                    if (!Guid.TryParseExact(identity, "D", out var id) ||
                        !Volatile.Read(ref _recentTitles).ContainsKey(id.ToString("D")))
                        return new(null, $"{window}:composer:{identity}", CanRetainThreadId: false);
                    return new(id.ToString("D"), $"{window}:composer:{id:D}", CanRetainThreadId: false);
                }
                if (node.GetParentNode(out var parent) < 0) return null;
                Marshal.ReleaseComObject(current);
                current = parent;
            }
            return null;
        }
        catch (Exception error) when (error is COMException or InvalidCastException)
        {
            return null;
        }
        finally { if (current is not null) Marshal.ReleaseComObject(current); }
    }

    private static Dictionary<string, string>? ReadComposerPortal(ISimpleDomNode root, CancellationToken token)
    {
        object? child = null;
        try
        {
            if (root.GetFirstChild(out child) < 0) return null;
            // In the supported Codex build the portal is a direct child of the
            // composer root. Do not search the chat transcript or another composer.
            for (var index = 0; index < 16 && child is ISimpleDomNode node; index++)
            {
                token.ThrowIfCancellationRequested();
                var attributes = ReadAttributes(node);
                if (attributes.ContainsKey("data-above-composer-portal")) return attributes;
                if (node.GetNextSibling(out var sibling) < 0) return null;
                Marshal.ReleaseComObject(child);
                child = sibling;
            }
            return null;
        }
        finally { if (child is not null) Marshal.ReleaseComObject(child); }
    }
}
