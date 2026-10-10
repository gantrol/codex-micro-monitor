using System.IO;
using System.Text.Json;
using CodexMicro.Core.Models;
using CodexMicro.Core.Services;

namespace CodexMicro.Desktop.Services;

internal sealed record CodexMonitoredTask(
    string Id,
    string Title,
    ThreadStatus Status,
    bool HasPendingQuestion = false,
    string? ErrorCode = null,
    CodexComposerDraftState DraftState = CodexComposerDraftState.Unknown);

internal sealed record CodexTaskMonitorSnapshot(
    CodexAgentRosterSnapshot AgentRoster,
    IReadOnlyList<CodexMonitoredTask> Tasks,
    long Revision);

internal sealed record CodexMonitoredQuestion(string ThreadId, CodexPendingQuestion Question);

internal sealed class CodexTaskMonitorService
{
    internal const int Capacity = 16;
    private sealed record RolloutReader(string Path, CodexRolloutStatusReader Reader);
    private sealed record CachedText(long Length, DateTime LastWriteTimeUtc, string Text);

    private readonly object _sync = new();
    private readonly string _codexRoot;
    private readonly Dictionary<string, RolloutReader> _readers =
        new(StringComparer.Ordinal);
    private readonly Dictionary<string, CachedText> _sharedText = new(StringComparer.Ordinal);
    private readonly Dictionary<string, HashSet<string>> _acceptedQuestionReplies =
        new(StringComparer.Ordinal);
    private readonly Dictionary<string, CodexRolloutStatusSnapshot> _rolloutStatuses = new(StringComparer.Ordinal);
    private readonly Dictionary<string, CodexThreadActivityObservation> _activity = new(StringComparer.Ordinal);
    private HashSet<string> _unread = new(StringComparer.Ordinal);
    private IReadOnlyDictionary<string, CodexComposerDraftState> _draftStates =
        new Dictionary<string, CodexComposerDraftState>(StringComparer.Ordinal);

    private readonly Func<CancellationToken, Task<IReadOnlyList<CodexRecentThread>?>> _readThreads;
    private readonly Func<CancellationToken, Task<CodexUnreadStateSnapshot?>> _readUnread;
    private CodexTaskMonitorSnapshot? _snapshot;
    private IReadOnlyList<CodexRecentThread>? _recentThreads;
    private IReadOnlyList<CodexRecentThread>? _rosterThreads;
    private string? _rosterGlobalState;
    private string? _rosterConfig;
    private long _revision;
    private long _unreadConfirmationRevision;

    // Selection metadata remains useful even if unread/status observation fails.
    internal IReadOnlyList<CodexRecentThread>? RecentThreads => Volatile.Read(ref _recentThreads);

    internal CodexTaskMonitorService(
        string? codexRoot = null,
        Func<CancellationToken, Task<IReadOnlyList<CodexRecentThread>?>>? readThreads = null,
        Func<CancellationToken, Task<CodexUnreadStateSnapshot?>>? readUnread = null)
    {
        _codexRoot = codexRoot ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        _readThreads = readThreads ?? (token => new CodexRecentThreadsService().ReadAsync(token, Capacity));
        _readUnread = readUnread ?? new CodexUnreadStateReader().ReadAsync;
    }

    internal CodexTaskMonitorSnapshot? ObserveUnreadConfirmed(string threadId)
    {
        lock (_sync)
        {
            ++_unreadConfirmationRevision;
            _unread.Add(threadId);
            if (_snapshot is null) return null;
            var tasks = _snapshot.Tasks.Select(task => task.Id == threadId &&
                task.Status is ThreadStatus.Idle or ThreadStatus.Unknown
                    ? task with { Status = ThreadStatus.CompleteUnread } : task).ToArray();
            return UpdateSnapshot(_snapshot.AgentRoster, tasks);
        }
    }

    internal CodexTaskMonitorSnapshot? ObserveActivity(CodexThreadActivityObservation observation)
    {
        lock (_sync)
        {
            if (_activity.TryGetValue(observation.ThreadId, out var previous) &&
                observation.Sequence <= previous.Sequence) return _snapshot;
            if (observation.Activity.Status == ThreadStatus.Unknown && !observation.Activity.HasCurrentTurn &&
                previous.Activity.HasCurrentTurn)
            {
                // Loss of observation cannot erase the identity of a newer
                // turn and expose an older rollout terminal record as current.
                observation = observation with { Activity = observation.Activity with
                {
                    TurnId = previous.Activity.TurnId,
                    HasCurrentTurn = true,
                } };
            }
            _activity[observation.ThreadId] = observation;
            if (_snapshot is null) return null;
            return UpdateSnapshot(_snapshot.AgentRoster, _snapshot.Tasks.Select(task =>
                task.Id == observation.ThreadId ? Project(task.Id, task.Title) : task).ToArray());
        }
    }

    private CodexMonitoredTask Project(string threadId, string title)
    {
        var rollout = _rolloutStatuses.GetValueOrDefault(threadId,
            new(ThreadStatus.Unknown, false));
        var runtime = _activity.TryGetValue(threadId, out var observed)
            ? observed.Activity : CodexThreadActivity.Unknown;
        var sameTurn = !runtime.HasCurrentTurn ||
            (runtime.TurnId is not null && runtime.TurnId == rollout.TurnId);
        var status = runtime.Status;
        // A terminal record is useful offline; an unclosed start is only
        // historical evidence and cannot assert that a turn is running now.
        if (status == ThreadStatus.Unknown && sameTurn)
            status = rollout.Status is ThreadStatus.Idle or ThreadStatus.Error
                ? rollout.Status : ThreadStatus.Unknown;
        else if (status == ThreadStatus.Idle && !runtime.HasCurrentTurn && rollout.Status == ThreadStatus.Error)
            status = ThreadStatus.Error;
        var question = runtime.Status == ThreadStatus.Thinking &&
            (runtime.HasPendingQuestion || (sameTurn && rollout.HasPendingQuestion));
        if (status is ThreadStatus.Idle or ThreadStatus.Unknown && _unread.Contains(threadId))
            status = ThreadStatus.CompleteUnread;
        return new(threadId, title, status, question,
            status == ThreadStatus.Error ? runtime.ErrorCode ?? (sameTurn ? rollout.ErrorCode : null) : null,
            _draftStates.GetValueOrDefault(threadId, CodexComposerDraftState.Unknown));
    }

    internal async Task<CodexTaskMonitorSnapshot?> ReadAsync(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        long confirmationRevision;
        lock (_sync) confirmationRevision = _unreadConfirmationRevision;
        var threadsRead = _readThreads(cancellationToken);
        var unreadRead = _readUnread(cancellationToken);
        await Task.WhenAll(threadsRead, unreadRead).ConfigureAwait(false);
        var threads = await threadsRead.ConfigureAwait(false);
        Volatile.Write(ref _recentThreads, threads);
        var unread = await unreadRead.ConfigureAwait(false);
        if (threads is null)
        {
            // Codex's app server can be unavailable while it restarts. Keep
            // task identities, but continue reading their lifecycle records.
            lock (_sync)
            {
                threads = _rosterThreads;
                if (threads is null) return _snapshot;
            }
        }

        return await Task.Run(() =>
        {
            lock (_sync)
            {
                cancellationToken.ThrowIfCancellationRequested();
                // A read started before a confirmed user action cannot undo it.
                if (confirmationRevision != _unreadConfirmationRevision) return _snapshot;
                // Unread lookup failure must not prevent live subscriptions
                // from starting or erase the last confirmed unread state.
                var globalState = ReadSharedText(".codex-global-state.json", out var globalStateCurrent);
                // Reuse this refresh's settings read. A cached settings fallback
                // remains useful for slot assignments, but is not live draft evidence.
                _draftStates = CodexComposerDraftReader.Read(globalStateCurrent ? globalState : null,
                    threads.Select(thread => thread.ThreadId));
                var tasks = ReadStatuses(threads, unread?.ThreadIds ?? _unread, cancellationToken);
                if (tasks is null)
                {
                    return null;
                }

                // Read source settings after the query so a source change cannot
                // restore the previous slot assignments while it is in flight.
                var config = ReadSharedText("config.toml", out _);
                var roster = _snapshot is not null && _rosterThreads is not null &&
                    ReferenceEquals(_rosterGlobalState, globalState) &&
                    ReferenceEquals(_rosterConfig, config) &&
                    _rosterThreads.SequenceEqual(threads)
                        ? _snapshot.AgentRoster
                        : CodexAgentRosterObserver.FromRecentThreads(threads, globalState, config);
                _rosterThreads = threads;
                _rosterGlobalState = globalState;
                _rosterConfig = config;
                return UpdateSnapshot(roster, tasks);
            }
        }, cancellationToken).ConfigureAwait(false);
    }

    internal Task<CodexTaskMonitorSnapshot?> ReadPendingQuestionsAsync(
        CancellationToken cancellationToken) =>
        ReadPendingQuestionsAsync(cancellationToken, null, null);

    internal IReadOnlyList<CodexMonitoredQuestion> GetPendingQuestions()
    {
        lock (_sync)
        {
            return _readers.Where(pair => _snapshot?.Tasks.Any(task =>
                task.Id == pair.Key && task.HasPendingQuestion) == true).SelectMany(pair => pair.Value.Reader
                .GetPendingQuestions(pair.Value.Path)
                .Select(question => new CodexMonitoredQuestion(pair.Key, question))).ToArray();
        }
    }

    internal Task<CodexTaskMonitorSnapshot?> ObserveSkippedQuestionAsync(
        CodexMonitoredQuestion question,
        CancellationToken cancellationToken)
    {
        lock (_sync)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (_readers.TryGetValue(question.ThreadId, out var reader))
            {
                reader.Reader.ObserveSkippedQuestion(reader.Path, question.Question);
            }
        }

        return ReadPendingQuestionsAsync(cancellationToken);
    }

    internal Task<CodexTaskMonitorSnapshot?> ObserveAcceptedQuestionRepliesAsync(
        string threadId,
        IReadOnlyList<string> replies,
        CancellationToken cancellationToken) =>
        ReadPendingQuestionsAsync(cancellationToken, threadId, replies);

    private Task<CodexTaskMonitorSnapshot?> ReadPendingQuestionsAsync(
        CancellationToken cancellationToken,
        string? answeredThreadId,
        IReadOnlyList<string>? replies)
    {
        return Task.Run(() =>
        {
            lock (_sync)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (answeredThreadId is not null && replies is not null)
                {
                    if (!_acceptedQuestionReplies.TryGetValue(answeredThreadId, out var accepted))
                    {
                        accepted = new(StringComparer.Ordinal);
                        _acceptedQuestionReplies[answeredThreadId] = accepted;
                    }
                    accepted.UnionWith(replies);
                }

                if (_snapshot is null)
                {
                    return null;
                }

                CodexMonitoredTask[]? updated = null;
                for (var index = 0; index < _snapshot.Tasks.Count; index++)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var task = _snapshot.Tasks[index];
                    if (!task.HasPendingQuestion || !_readers.TryGetValue(task.Id, out var reader))
                    {
                        continue;
                    }

                    _acceptedQuestionReplies.TryGetValue(task.Id, out var acceptedReplies);
                    var rollout = reader.Reader.ReadSnapshot(reader.Path, acceptedReplies);
                    _rolloutStatuses[task.Id] = rollout;
                    var projected = Project(task.Id, task.Title);
                    if (projected == task)
                    {
                        continue;
                    }

                    updated ??= _snapshot.Tasks.ToArray();
                    updated[index] = projected;
                }

                return updated is null ? _snapshot : UpdateSnapshot(_snapshot.AgentRoster, updated);
            }
        }, cancellationToken);
    }

    private CodexTaskMonitorSnapshot UpdateSnapshot(
        CodexAgentRosterSnapshot roster,
        IReadOnlyList<CodexMonitoredTask> tasks)
    {
        if (_snapshot is { } previous &&
            previous.AgentRoster.Source == roster.Source &&
            previous.AgentRoster.Entries.SequenceEqual(roster.Entries) &&
            previous.Tasks.SequenceEqual(tasks))
        {
            return previous;
        }

        return _snapshot = new CodexTaskMonitorSnapshot(roster, tasks, ++_revision);
    }

    private string? ReadSharedText(string name, out bool current)
    {
        current = false;
        try
        {
            var path = Path.Combine(_codexRoot, name);
            var file = new FileInfo(path);
            if (!file.Exists)
            {
                _sharedText.Remove(name);
                return null;
            }

            if (_sharedText.TryGetValue(name, out var cached) &&
                cached.Length == file.Length && cached.LastWriteTimeUtc == file.LastWriteTimeUtc)
            {
                current = true;
                return cached.Text;
            }

            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            var text = reader.ReadToEnd();
            _sharedText[name] = new CachedText(file.Length, file.LastWriteTimeUtc, text);
            current = true;
            return text;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Settings availability does not determine task activity or the
            // validity of its independent IPC subscription.
            return _sharedText.GetValueOrDefault(name)?.Text;
        }
    }

    private IReadOnlyList<CodexMonitoredTask>? ReadStatuses(
        IReadOnlyList<CodexRecentThread> threads,
        IReadOnlySet<string> unread,
        CancellationToken cancellationToken)
    {
        try
        {
            var tasks = new List<CodexMonitoredTask>(Capacity);
            _unread = new(unread, StringComparer.Ordinal);
            var retained = new HashSet<string>(StringComparer.Ordinal);
            foreach (var thread in threads)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!Guid.TryParse(thread.ThreadId, out _) ||
                    thread.RolloutPath?.Contains("trash", StringComparison.OrdinalIgnoreCase) == true ||
                    !retained.Add(thread.ThreadId))
                {
                    continue;
                }

                var path = NormalizeRolloutPath(thread.RolloutPath);
                _rolloutStatuses[thread.ThreadId] = new(ThreadStatus.Unknown, false);
                if (path is not null)
                {
                    if (!_readers.TryGetValue(thread.ThreadId, out var reader) ||
                        !string.Equals(reader.Path, path, StringComparison.OrdinalIgnoreCase))
                    {
                        reader = new RolloutReader(path,
                            new CodexRolloutStatusReader(CodexRolloutFileIdentity.Read));
                        _readers[thread.ThreadId] = reader;
                    }
                    _acceptedQuestionReplies.TryGetValue(thread.ThreadId, out var acceptedReplies);
                    _rolloutStatuses[thread.ThreadId] = reader.Reader.ReadSnapshot(path, acceptedReplies);
                }

                // A missing rollout affects state only; do not replace a recent
                // task with an older task because of its path or availability.
                tasks.Add(Project(thread.ThreadId, thread.Title));
            }

            foreach (var id in _readers.Keys.Where(id => !retained.Contains(id)).ToArray())
            {
                _readers.Remove(id);
            }

            foreach (var id in _rolloutStatuses.Keys.Where(id => !retained.Contains(id)).ToArray())
                _rolloutStatuses.Remove(id);
            foreach (var id in _activity.Keys.Where(id => !retained.Contains(id)).ToArray())
                _activity.Remove(id);

            foreach (var id in _acceptedQuestionReplies.Keys.Where(id => !retained.Contains(id)).ToArray())
            {
                _acceptedQuestionReplies.Remove(id);
            }

            return tasks;
        }
        catch (Exception exception) when (exception is
            IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    private string? NormalizeRolloutPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !IsAllowedPath(path))
        {
            return null;
        }

        try
        {
            if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
            {
                path = @"\\" + path[8..];
            }
            else if (path.StartsWith(@"\\?\", StringComparison.Ordinal))
            {
                path = path[4..];
            }

            if (!Path.IsPathFullyQualified(path))
            {
                return null;
            }

            var normalized = Path.GetFullPath(path);
            var sessionsRoot = Path.GetFullPath(Path.Combine(_codexRoot, "sessions")) +
                Path.DirectorySeparatorChar;
            return normalized.StartsWith(sessionsRoot, StringComparison.OrdinalIgnoreCase)
                ? normalized : null;
        }
        catch (Exception exception) when (exception is
            ArgumentException or NotSupportedException or IOException)
        {
            return null;
        }
    }

    private static bool IsAllowedPath(string path) =>
        !path.Contains("trash", StringComparison.OrdinalIgnoreCase);
}
