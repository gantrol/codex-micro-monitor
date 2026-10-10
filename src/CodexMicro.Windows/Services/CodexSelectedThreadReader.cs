using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Automation;
using CodexMicro.Codex;

namespace CodexMicro.Desktop.Services;

internal readonly record struct CodexThreadSelection(
    string? ThreadId, string? PageKey, bool CanRetainThreadId = true);

internal sealed partial class CodexSelectedThreadReader
{
    private readonly SemaphoreSlim _gate = new(1);
    private readonly string _indexPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "session_index.jsonl");
    private DateTime _indexModified;
    private long _indexLength = -1;
    private Dictionary<string, string> _titles = new(StringComparer.Ordinal);
    private IReadOnlyDictionary<string, string> _recentTitles = new Dictionary<string, string>(StringComparer.Ordinal);
    private nint _lastWindow;
    private readonly CodexDesktopRouteReader _desktopRoutes = new();
    private (CodexThreadSelection Selection, string Source)? _lastDiagnostic;
#if DEBUG
    private string? _routeRejection;
#endif

    internal bool ObserveRecentThreads(IReadOnlyList<CodexRecentThread>? threads)
    {
        var titles = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var thread in threads ?? [])
        {
            if (Guid.TryParse(thread.ThreadId, out _) && !string.IsNullOrWhiteSpace(thread.Title) &&
                thread.RolloutPath?.Contains("trash", StringComparison.OrdinalIgnoreCase) != true)
                titles[thread.ThreadId] = thread.Title;
        }
        var previous = Volatile.Read(ref _recentTitles);
        if (previous.Count == titles.Count && titles.All(pair =>
                previous.TryGetValue(pair.Key, out var title) && title == pair.Value)) return false;
        Volatile.Write(ref _recentTitles, titles);
        return true;
    }

    internal async Task<CodexThreadSelection> ReadSelectionAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run<CodexThreadSelection>(async () =>
            {
                cancellationToken.ThrowIfCancellationRequested();
#if DEBUG
                _routeRejection = null;
#endif
                // Finish disk I/O before observing the page. A chat switch during an
                // index read must not make an old header authorize a new operation.
                try { await RefreshTitlesAsync(cancellationToken).ConfigureAwait(false); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
#if DEBUG
                    CodexModelToggleDiagnostics.RecordStage("selection-index-unavailable", new { error = error.GetType().Name });
#endif
                    _titles.Clear();
                    _indexLength = -1;
                }
                for (var attempt = 0; attempt < 2; attempt++)
                {
                    var window = CodexWindowActivator.FindSelectionWindow(_lastWindow);
                    _lastWindow = window;
                    if (window == nint.Zero) return RecordSelection(default, "window-unavailable");
                    GetWindowThreadProcessId(window, out var processId);
                    // Refresh even when no DOM identity was readable. This is the
                    // essential draft -> real thread transition with a hidden sidebar.
                    await _desktopRoutes.RefreshAsync(processId, cancellationToken, force: true).ConfigureAwait(false);
                    if (CodexWindowActivator.FindSelectionWindow(window) != window) continue;
                    if (_desktopRoutes.TryReadSingleWindow(processId, out var desktopRoute) &&
                        CodexWindowActivator.IsOnlySelectionWindow(window, processId))
                    {
                        var desktopId = ResolveDocumentThreadId(new Uri("app://-" + desktopRoute.Path));
                        return RecordSelection(new(desktopId, $"{window}:route:{desktopRoute.Path}",
                            CanRetainThreadId: false), "desktop-window-route");
                    }
#if DEBUG
                    _routeRejection = _desktopRoutes.TryReadSingleWindow(processId, out _)
                        ? "native-window-not-unique" : "logged-window-route-unavailable";
#endif
                    if (TryReadDocumentThreadId(window, cancellationToken, out var threadId, out var route))
                    {
                        var identity = route is null ? null : Uri.UnescapeDataString(new Uri(route).AbsolutePath);
                        var clientId = identity?.StartsWith("/local/", StringComparison.Ordinal) == true ? identity[7..] : null;
                        if (CodexDesktopRouteReader.IsClientThreadId(clientId))
                        {
                            // The composer can already have the formal ID while the
                            // route still contains the frontend creation identity.
                            if (ReadComposerSelection(window, cancellationToken) is { ThreadId: not null } boundComposer)
                                return RecordSelection(boundComposer, "composer");
                            threadId = _desktopRoutes.Resolve(clientId!, processId);
                            if (threadId is null && attempt == 0)
                            {
                                await _desktopRoutes.RefreshAsync(processId, cancellationToken).ConfigureAwait(false);
                                continue; // Re-observe the page after I/O, including foreground-window changes.
                            }
                        }
                        return RecordSelection(new(threadId, route is null ? null : $"{window}:{route}",
                            CanRetainThreadId: false), "document-route");
                    }
                    if (ReadComposerSelection(window, cancellationToken) is { } composer)
                        return RecordSelection(composer, "composer");
                    var header = ReadHeader(window, cancellationToken);
                    var rows = ReadSelectedRows(window);
                    if (rows.Length > 1) return RecordSelection(default, "sidebar-ambiguous");
                    if (rows.Length == 0)
                        return RecordSelection(new(null, header?.Key, CanRetainThreadId: header is not null), "header-only");
                    var row = rows[0];
                    var resolved = row.Identity is null ? null : _desktopRoutes.Resolve(row.Identity, processId);
                    if (resolved is null && CodexDesktopRouteReader.IsClientThreadId(row.Identity) && attempt == 0)
                    {
                        await _desktopRoutes.RefreshAsync(processId, cancellationToken).ConfigureAwait(false);
                        continue;
                    }
                    // A title checks consistency; it never supplies the identity.
                    if (resolved is null || header is { } visible && visible.Title != row.Title &&
                        Resolve([visible.Title], _titles, Volatile.Read(ref _recentTitles)) != resolved)
                        return RecordSelection(new(null, header?.Key, CanRetainThreadId: false), "sidebar-unresolved");
                    return RecordSelection(new(resolved, header?.Key ?? $"{window}:sidebar:{row.Identity}"), "sidebar");
                }
                return RecordSelection(default, "window-changed");
            }, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (error is COMException or ElementNotAvailableException or IOException or
            UnauthorizedAccessException or InvalidOperationException or ArgumentException)
        {
#if DEBUG
            CodexModelToggleDiagnostics.RecordStage("selection-failed", new
            {
                error = error.GetType().Name, error.HResult, routes = _desktopRoutes.CaptureDiagnostics(),
            });
#endif
            return default;
        }
        finally { _gate.Release(); }
    }

    internal async Task<string?> ReadAsync(CancellationToken cancellationToken = default) =>
        (await ReadSelectionAsync(cancellationToken).ConfigureAwait(false)).ThreadId;

    private CodexThreadSelection RecordSelection(CodexThreadSelection selection, string source)
    {
#if DEBUG
        if (_lastDiagnostic != (selection, source) || System.Diagnostics.Activity.Current is not null)
            CodexModelToggleDiagnostics.RecordStage("selection-observed", new
            {
                source, selection.ThreadId, selection.CanRetainThreadId,
                hasPageIdentity = selection.PageKey is not null,
                routeRejection = source == "desktop-window-route" ? null : _routeRejection,
                routes = _desktopRoutes.CaptureDiagnostics(),
            });
#endif
        if (_lastDiagnostic != (selection, source))
        {
            _lastDiagnostic = (selection, source);
            // Existing small, synchronous diagnostic sink; called on this reader's
            // worker task, only on transitions. Do not write titles or page contents.
            SoftwareControlDiagnostics.Write($"selection-observed source={source} threadId={selection.ThreadId ?? "none"} retain={selection.CanRetainThreadId}");
        }
        return selection;
    }

    internal static string? Resolve(IEnumerable<string> selectedTitles, IReadOnlyDictionary<string, string> titles,
        IReadOnlyDictionary<string, string>? recentTitles = null)
    {
        var selected = selectedTitles.ToHashSet(StringComparer.Ordinal);
        // Neither source is always newer. Retain both aliases so a stale roster
        // cannot erase a newly indexed name and make another chat look unique.
        var candidates = recentTitles is null ? titles : titles.Concat(recentTitles);
        var matches = candidates.Where(pair => selected.Contains(pair.Value))
            .Select(pair => pair.Key).Distinct(StringComparer.Ordinal).Take(2).ToArray();
        // Titles only recover an observed ID. Never choose arbitrarily among duplicates.
        return matches.Length == 1 ? matches[0] : null;
    }

    private static (string Title, string Key)? ReadHeader(nint window, CancellationToken token)
    {
        var root = AutomationElement.FromHandle(window);
        var cache = new CacheRequest();
        cache.Add(AutomationElement.NameProperty);
        cache.Add(AutomationElement.IsOffscreenProperty);
        AutomationElementCollection toolbars;
        using (cache.Activate())
            toolbars = root.FindAll(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ToolBar));
        var headers = new List<(string Title, string Key)>();
        foreach (AutomationElement toolbar in toolbars)
        {
            token.ThrowIfCancellationRequested();
            if (toolbar.Cached.IsOffscreen) continue;
            var parent = TreeWalker.RawViewWalker.GetParent(toolbar);
            var inHeader = false;
            for (var depth = 0; parent is not null && depth < 10; depth++)
            {
                token.ThrowIfCancellationRequested();
                if (parent.Current.ClassName.Split(' ').Contains("group/titlebar"))
                {
                    inHeader = true;
                    break;
                }
                parent = TreeWalker.RawViewWalker.GetParent(parent);
            }
            if (!inHeader) continue;
            AutomationElementCollection texts;
            using (cache.Activate())
                texts = toolbar.FindAll(TreeScope.Descendants,
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text));
            foreach (AutomationElement text in texts)
            {
                if (text.Cached.IsOffscreen || string.IsNullOrWhiteSpace(text.Cached.Name)) continue;
                // Chromium can omit the title container from ControlView even though its
                // text is visible. Only inspect raw ancestors inside this header toolbar.
                parent = TreeWalker.RawViewWalker.GetParent(text);
                for (var depth = 0; parent is not null && depth < 8; depth++)
                {
                    token.ThrowIfCancellationRequested();
                    if (parent.Current.ControlType == ControlType.ToolBar) break;
                    var css = parent.Current.ClassName.Split(' ');
                    if (css.Contains("-ms-0.5") && css.Contains("font-medium") && css.Contains("truncate"))
                    {
                        var key = $"{window}:{string.Join('.', toolbar.GetRuntimeId())}:{string.Join('.', parent.GetRuntimeId())}:{text.Cached.Name}";
                        headers.Add((text.Cached.Name, key));
                        break;
                    }
                    parent = TreeWalker.RawViewWalker.GetParent(parent);
                }
            }
        }
        return headers.Count == 1 ? headers[0] : null;
    }

    internal static string? ResolveDocumentThreadId(Uri documentUrl)
    {
        if (!IsCodexDocument(documentUrl)) return null;
        // A remote connection also uses /local/<UUID>, but is not a local IPC target.
        if (documentUrl.Query.TrimStart('?').Split('&')
            .Select(part => part.Split('=', 2))
            .Any(parts => parts.Length == 2 && parts[0] == "hostId" &&
                Uri.UnescapeDataString(parts[1]) is not ("" or "local"))) return null;

        var path = documentUrl.AbsolutePath;
        // Some desktop builds retain the bootstrap URL after client-side navigation.
        if (path is "/index.html" or "/detached-window.html")
        {
            var routes = documentUrl.Query.TrimStart('?').Split('&')
                .Select(part => part.Split('=', 2))
                .Where(parts => parts.Length == 2 && parts[0] == "initialRoute")
                .Select(parts => Uri.UnescapeDataString(parts[1])).ToArray();
            if (routes.Length != 1) return null;
            path = routes[0];
        }

        var segments = path.Split(['?', '#'], 2)[0].Split('/');
        return segments.Length == 3 && segments[0].Length == 0 && segments[1] == "local" &&
            Guid.TryParseExact(Uri.UnescapeDataString(segments[2]), "D", out var threadId)
                ? threadId.ToString("D") : null;
    }

    private static bool IsCodexDocument(Uri url) =>
        url.IsAbsoluteUri && url.Scheme == "app" && url.Host == "-";

    // A bare bootstrap URL contains no selection evidence; allow the sidebar
    // fallback instead of interpreting it as an authoritative home/settings route.
    internal static bool HasDocumentRoute(Uri url) => IsCodexDocument(url) &&
        (url.AbsolutePath is not ("/index.html" or "/detached-window.html") ||
         url.Query.TrimStart('?').Split('&').Any(part => part.StartsWith("initialRoute=", StringComparison.Ordinal)));

    private static bool TryReadDocumentThreadId(
        nint window, CancellationToken cancellationToken, out string? threadId, out string? route)
    {
        threadId = null;
        route = null;
        IAutomation? client = null;
        IElement? root = null;
        ICondition? condition = null;
        IElements? documents = null;
        try
        {
            client = (IAutomation)Activator.CreateInstance(Type.GetTypeFromCLSID(
                new Guid("ff48dba4-60ef-4201-aa87-54103eef594e"))!)!;
            root = client.ElementFromHandle(window);
            condition = client.CreatePropertyConditionEx(30003, 50030, 0); // Document control type.
            documents = root.FindAll(4, condition);
            var routes = new HashSet<string>(StringComparer.Ordinal);
            for (var index = 0; index < documents.Length; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var document = documents.GetElement(index);
                object? pattern = null;
                try
                {
                    if (document.GetCurrentPropertyValue(30022) is not false) continue; // IsOffscreen.
                    // Chromium exposes the document URL through IValueProvider.get_Value.
                    // Read the pattern, not the element's ValueValue property: the latter
                    // only exposes an explicit DOM value and may be empty for documents.
                    pattern = document.GetCurrentPattern(10002); // Value pattern.
                    if (pattern is IValuePattern value &&
                        Uri.TryCreate(value.CurrentValue, UriKind.Absolute, out var url) && HasDocumentRoute(url))
                    {
                        // initialRoute describes window startup, not subsequent client-side
                        // navigation. Only a live route can authorize IPC for a thread ID.
                        if (url.AbsolutePath is "/index.html" or "/detached-window.html") continue;
                        routes.Add(url.AbsoluteUri);
                    }
                }
                catch (COMException)
                {
                    // Embedded documents (for example PDFs) need not support Value.
                }
                finally
                {
                    if (pattern is not null) Marshal.ReleaseComObject(pattern);
                    Marshal.ReleaseComObject(document);
                }
            }

            // A readable home/settings route is authoritative too. Do not restore a
            // sidebar title or a previous thread when this window has left that chat.
            if (routes.Count == 1)
            {
                route = routes.Single();
                threadId = ResolveDocumentThreadId(new Uri(route));
            }
            return routes.Count != 0;
        }
        finally
        {
            if (documents is not null) Marshal.ReleaseComObject(documents);
            if (condition is not null) Marshal.ReleaseComObject(condition);
            if (root is not null) Marshal.ReleaseComObject(root);
            if (client is not null) Marshal.ReleaseComObject(client);
        }
    }

    private async Task RefreshTitlesAsync(CancellationToken cancellationToken)
    {
        var file = new FileInfo(_indexPath);
        if (!file.Exists) { _titles.Clear(); return; }
        if (file.LastWriteTimeUtc == _indexModified && file.Length == _indexLength) return;
        var titles = new Dictionary<string, string>(StringComparer.Ordinal);
        await using var stream = new FileStream(_indexPath, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.Asynchronous | FileOptions.SequentialScan);
        using var reader = new StreamReader(stream);
        while (await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false) is { } line)
        {
            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (root.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String &&
                    Guid.TryParse(id.GetString(), out _) &&
                    root.TryGetProperty("thread_name", out var title) && title.ValueKind == JsonValueKind.String)
                    titles[id.GetString()!] = title.GetString()!;
            }
            catch (JsonException) { }
        }
        _titles = titles;
        _indexModified = file.LastWriteTimeUtc;
        _indexLength = file.Length;
    }

    internal static string[] ReadSelectedTitles(nint window) =>
        ReadSelectedRows(window).Select(row => row.Title).ToArray();

    private static SidebarRow[] ReadSelectedRows(nint window)
    {
        IAutomation? client = null;
        IElement? root = null;
        ICondition? condition = null;
        IElements? selected = null;
        try
        {
            client = (IAutomation)Activator.CreateInstance(Type.GetTypeFromCLSID(
                new Guid("ff48dba4-60ef-4201-aa87-54103eef594e"))!)!;
            root = client.ElementFromHandle(window);
            condition = client.CreatePropertyConditionEx(30102, "current=page", 2);
            selected = root.FindAll(4, condition);
            var rows = new List<SidebarRow>();
            for (var index = 0; index < selected.Length; index++)
            {
                var node = selected.GetElement(index);
                try
                {
                    if (node.GetCurrentPropertyValue(30022) is false &&
                        node.GetCurrentPropertyValue(30012) is string css &&
                        css.Split(' ').Contains("sidebar-item", StringComparer.Ordinal) &&
                        node.GetCurrentPropertyValue(30005) is string title && title.Length > 0)
                        rows.Add(new(title, ReadSidebarIdentity(window, node)));
                }
                finally { Marshal.ReleaseComObject(node); }
            }
            return rows.ToArray();
        }
        finally
        {
            if (selected is not null) Marshal.ReleaseComObject(selected);
            if (condition is not null) Marshal.ReleaseComObject(condition);
            if (root is not null) Marshal.ReleaseComObject(root);
            if (client is not null) Marshal.ReleaseComObject(client);
        }
    }

    // The Windows SDK IUIAutomation vtable. Only read operations are exposed.
    [ComImport, Guid("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAutomation
    {
        void Slot0(); void Slot1(); void Slot2();
        IElement ElementFromHandle(nint handle);
        void Slot4(); void Slot5(); void Slot6(); void Slot7(); void Slot8(); void Slot9();
        void Slot10(); void Slot11(); void Slot12(); void Slot13(); void Slot14(); void Slot15(); void Slot16(); void Slot17();
        void Slot18(); void Slot19(); void Slot20();
        ICondition CreatePropertyConditionEx(int property, [MarshalAs(UnmanagedType.Struct)] object value, int flags);
    }
    [ComImport, Guid("d22108aa-8ac5-49a5-837b-37bbb3d7591e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IElement
    {
        void Slot0(); void Slot1(); void Slot2();
        IElements FindAll(int scope, ICondition condition);
        void Slot4(); void Slot5(); void Slot6();
        [return: MarshalAs(UnmanagedType.Struct)] object GetCurrentPropertyValue(int property);
        void Slot8(); void Slot9(); void Slot10(); void Slot11(); void Slot12();
        [return: MarshalAs(UnmanagedType.IUnknown)] object? GetCurrentPattern(int patternId);
    }
    [ComImport, Guid("a94cd8b1-0844-4cd6-9d2d-640537ab39e9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IValuePattern
    {
        void Slot0();
        string CurrentValue { [return: MarshalAs(UnmanagedType.BStr)] get; }
    }
    [ComImport, Guid("352ffba8-0973-437c-a61f-f64cafd81df9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ICondition { }
    [ComImport, Guid("14314595-b4bc-4055-95f2-58f2e42c9855"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IElements { int Length { get; } IElement GetElement(int index); }
}
