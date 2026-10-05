using System.IO;
using System.Text;
using System.Globalization;

namespace CodexMicro.Desktop.Services;

internal readonly record struct CodexDesktopRoute(int WindowId, string Path, DateTimeOffset ObservedAt);

// Calls are serialized by CodexSelectedThreadReader and run off the Dispatcher.
// The caller must match the native window before using a logged window route.
internal sealed class CodexDesktopRouteReader
{
    private readonly Dictionary<string, string?> _threads = new(StringComparer.Ordinal);
    private readonly Dictionary<string, long> _offsets = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<int, CodexDesktopRoute> _routes = [];
    private uint _processId;
    private DateTimeOffset _nextRefresh;
    private bool _available;

    internal static bool IsClientThreadId(string? value) =>
        value is not null && value.StartsWith("client-new-thread:", StringComparison.Ordinal) &&
        Guid.TryParseExact(value[18..], "D", out _);

    internal string? Resolve(string identity, uint processId) =>
        Guid.TryParseExact(identity, "D", out var id) ? id.ToString("D") :
        processId == _processId ? _threads.GetValueOrDefault(identity) : null;

    internal bool TryReadSingleWindow(uint processId, out CodexDesktopRoute route)
    {
        route = default;
        if (!_available || processId != _processId || _routes.Count != 1) return false;
        route = _routes.Values.Single();
        return true;
    }

    internal async Task RefreshAsync(uint processId, CancellationToken token, bool force = false)
    {
        if (processId == 0) return;
        if (_processId != processId)
        {
            _processId = processId;
            _threads.Clear();
            _offsets.Clear();
            _routes.Clear();
            _available = false;
            _nextRefresh = default;
        }
        var now = DateTimeOffset.UtcNow;
        if (!force && now < _nextRefresh) return;
        _nextRefresh = now.AddSeconds(1);
        _available = false;
        var readAny = false;
        var readFailed = false;
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string[] roots =
        [
            Path.Combine(local, "Packages", "OpenAI.Codex_2p2nqsd0c76g0", "LocalCache", "Local", "Codex", "Logs"),
            Path.Combine(local, "Codex", "Logs"),
        ];
        // Only the current Electron main process, in the two recent UTC day folders.
        // Directory metadata is synchronous, bounded, and read on the worker task.
        foreach (var root in roots)
        for (var day = 0; day < 2; day++)
        {
            var date = now.AddDays(-day);
            var directory = Path.Combine(root, date.ToString("yyyy"), date.ToString("MM"), date.ToString("dd"));
            if (directory.Contains("trash", StringComparison.OrdinalIgnoreCase)) continue;
            try
            {
                if (!Directory.Exists(directory)) continue;
                foreach (var path in Directory.EnumerateFiles(directory, $"codex-desktop-*-{processId}-t0-*.log")
                    .Where(path => !path.Contains("trash", StringComparison.OrdinalIgnoreCase))
                    .OrderDescending(StringComparer.Ordinal).Take(8))
                {
                    await ReadAsync(path, token).ConfigureAwait(false);
                    readAny = true;
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { readFailed = true; }
        }
        _available = readAny && !readFailed;
    }

    private async Task ReadAsync(string path, CancellationToken token)
    {
        const int maximumBytes = 4 * 1024 * 1024;
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.Asynchronous | FileOptions.SequentialScan);
        var length = stream.Length;
        var known = _offsets.TryGetValue(path, out var offset) && offset <= length;
        var start = Math.Max(known ? offset : 0, length - maximumBytes);
        var skipFirstLine = start > (known ? offset : 0);
        stream.Position = start;
        var bytes = new byte[(int)(length - start)];
        var read = 0;
        while (read < bytes.Length)
        {
            var count = await stream.ReadAsync(bytes.AsMemory(read), token).ConfigureAwait(false);
            if (count == 0) break;
            read += count;
        }
        var lineStart = 0;
        for (var index = 0; index < read; index++)
        {
            if (bytes[index] != (byte)'\n') continue;
            if (!skipFirstLine)
                Observe(Encoding.UTF8.GetString(bytes, lineStart, index - lineStart));
            skipFirstLine = false;
            lineStart = index + 1;
        }
        // An incomplete last line is read again after the writer finishes it.
        _offsets[path] = start + lineStart;
    }

    private void Observe(string line)
    {
        if (!line.Contains("[electron-message-handler] IAB_LIFECYCLE received browser sidebar owner sync ",
                StringComparison.Ordinal)) return;
        var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var window = fields.FirstOrDefault(field => field.StartsWith("windowId=", StringComparison.Ordinal))?[9..];
        var client = fields.FirstOrDefault(field => field.StartsWith("conversationId=", StringComparison.Ordinal))?[15..];
        var route = fields.FirstOrDefault(field => field.StartsWith("ownerRoutePath=", StringComparison.Ordinal))?[15..];
        if (route is null || !route.StartsWith('/') || route.StartsWith("//", StringComparison.Ordinal) ||
            !Uri.TryCreate("app://-" + route, UriKind.Absolute, out var url) ||
            !int.TryParse(window, NumberStyles.None, CultureInfo.InvariantCulture, out var windowId) || windowId <= 0 ||
            !DateTimeOffset.TryParse(fields[0], CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal,
                out var observedAt)) return;
        // Home, draft, and settings routes also replace the previous chat. File
        // enumeration order must never let an older rotated log restore an old route.
        if (!_routes.TryGetValue(windowId, out var previousRoute) || previousRoute.ObservedAt <= observedAt)
            _routes[windowId] = new(windowId, route, observedAt);
        if (!IsClientThreadId(client) || CodexSelectedThreadReader.ResolveDocumentThreadId(url) is not { } threadId) return;
        // A contradictory mapping remains unresolved; never pick whichever arrived last.
        _threads[client!] = _threads.TryGetValue(client!, out var previous) && previous != threadId
            ? null : threadId;
    }
}
