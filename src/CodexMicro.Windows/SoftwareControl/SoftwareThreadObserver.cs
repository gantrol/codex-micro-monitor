using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using CodexMicro.Desktop.Services;

namespace CodexMicro.Codex;

// Observes live task activity and accepted question replies on the same stream.
internal sealed class SoftwareThreadObserver : IDisposable, IAsyncDisposable
{
    private sealed class Subscription(string threadId, string owner)
    {
        internal CodexThreadModelStateAccumulator Stream { get; } = new(threadId, owner);
        internal TaskCompletionSource Ready { get; set; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal CodexThreadActivity? LastActivity { get; set; }
        internal long LastMessageAt { get; set; } = Stopwatch.GetTimestamp();
    }

    private readonly ICodexDesktopConnection _peer;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly object _sync = new();
    private readonly Dictionary<string, Subscription> _streams = new(StringComparer.Ordinal);
    private readonly HashSet<string> _resync = new(StringComparer.Ordinal);
    private HashSet<string> _wanted = new(StringComparer.Ordinal);
    private Task? _refresh;
    private Task? _dispose;
    private bool _refreshRequested;
    private bool _disposed;
    private long _sequence;
    private long _connectionGeneration;
    // This renews observation, never infers a task outcome from elapsed time.
    private static readonly TimeSpan ReconfirmInterval = TimeSpan.FromSeconds(30);

    internal event Action<string, IReadOnlyList<string>>? AnswersAccepted;
    internal event Action<CodexThreadActivityObservation>? ActivityChanged;

    internal SoftwareThreadObserver(ICodexDesktopConnection? peer = null)
    {
        _peer = peer ?? new CodexDesktopConnection();
        _peer.Broadcast += OnBroadcast;
        _peer.Disconnected += OnDisconnected;
    }

    internal Task RefreshAsync(IEnumerable<string> threadIds)
    {
        List<CodexThreadActivityObservation> observations = [];
        Task refresh;
        lock (_sync)
        {
            if (_disposed) return Task.CompletedTask;
            _wanted = threadIds.Take(CodexTaskMonitorService.Capacity).ToHashSet(StringComparer.Ordinal);
            foreach (var id in _streams.Keys.Where(id => !_wanted.Contains(id))) Invalidate(id, observations);
            _refreshRequested = true;
            refresh = _refresh ??= Task.Run(RefreshCoreAsync);
        }
        if (observations.Count > 0)
            return Task.Run(async () => { Publish(observations); await refresh.ConfigureAwait(false); });
        return refresh;
    }

    private async Task RefreshCoreAsync()
    {
        while (true)
        {
            string[] wanted;
            Subscription[] removed;
            lock (_sync)
            {
                if (_disposed || !_refreshRequested) { _refresh = null; return; }
                _refreshRequested = false;
                wanted = _wanted.ToArray();
                removed = _streams.Values.Where(subscription =>
                    !_wanted.Contains(subscription.Stream.ThreadId) || _resync.Contains(subscription.Stream.ThreadId)).ToArray();
                foreach (var subscription in removed)
                {
                    _streams.Remove(subscription.Stream.ThreadId);
                    _resync.Remove(subscription.Stream.ThreadId);
                }
            }
            try
            {
                if (wanted.Length == 0 && removed.Length == 0) continue;
                await _peer.ConnectAsync(_lifetime.Token).ConfigureAwait(false);
                foreach (var subscription in removed)
                {
                    var stream = subscription.Stream;
                    await _peer.FollowAsync(stream.ThreadId, stream.OwnerClientId, false, _lifetime.Token).ConfigureAwait(false);
                }
                // One unavailable owner must not block the remaining keys.
                await Parallel.ForEachAsync(wanted, new ParallelOptions
                {
                    MaxDegreeOfParallelism = 4, CancellationToken = _lifetime.Token,
                }, async (id, token) => await SubscribeAsync(id, token)).ConfigureAwait(false);
            }
            catch (Exception error) when (IsUnavailable(error))
            {
                OnDisconnected();
                SoftwareControlDiagnostics.Write("thread-observer-unavailable", error);
            }
        }
    }

    private async Task SubscribeAsync(string id, CancellationToken token)
    {
        Subscription? subscription = null;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(2));
        try
        {
            long generation;
            Subscription? existing;
            lock (_sync)
            {
                if (_disposed || !_wanted.Contains(id)) return;
                existing = _streams.GetValueOrDefault(id);
                if (existing is not null && Stopwatch.GetElapsedTime(existing.LastMessageAt) < ReconfirmInterval) return;
                generation = _connectionGeneration;
            }
            var owner = (await _peer.RequestAsync("thread-owner-discovery", 1,
                new { hostId = "local", conversationId = id }, null, timeout.Token).ConfigureAwait(false))
                .Required("handledByClientId");
            List<CodexThreadActivityObservation> observations = [];
            lock (_sync)
            {
                if (_disposed || !_wanted.Contains(id) || generation != _connectionGeneration ||
                    _resync.Contains(id) || _streams.GetValueOrDefault(id) != existing) return;
                if (existing is not null && existing.Stream.OwnerClientId == owner)
                {
                    subscription = existing;
                    subscription.Ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
                }
                else
                {
                    if (existing is not null)
                        observations.Add(new(id, ++_sequence, UnavailableActivity(existing)));
                    subscription = new(id, owner);
                }
                _streams[id] = subscription;
            }
            Publish(observations);
            if (existing is not null && existing != subscription)
                await _peer.FollowAsync(id, existing.Stream.OwnerClientId, false, timeout.Token).ConfigureAwait(false);
            await _peer.FollowAsync(id, owner, true, timeout.Token).ConfigureAwait(false);
            await subscription.Ready.Task.WaitAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (Exception error) when (IsUnavailable(error))
        {
            List<CodexThreadActivityObservation> observations = [];
            lock (_sync)
            {
                if (subscription is not null && _streams.GetValueOrDefault(id) == subscription)
                    Invalidate(id, observations);
                else if (subscription is null && _streams.ContainsKey(id))
                    Invalidate(id, observations);
            }
            Publish(observations);
            SoftwareControlDiagnostics.Write("thread-observer-unavailable", error);
        }
    }

    // Never call the monitor while holding the subscription lock: its worker
    // may be reading rollout files. Sequence numbers reject reordered delivery.
    private void Publish(IEnumerable<CodexThreadActivityObservation> observations)
    {
        foreach (var observation in observations) ActivityChanged?.Invoke(observation);
    }

    private void Invalidate(string id, List<CodexThreadActivityObservation> observations)
    {
        _streams.TryGetValue(id, out var subscription);
        if (_resync.Add(id))
            observations.Add(new(id, ++_sequence, UnavailableActivity(subscription)));
        subscription?.Ready.TrySetResult();
    }

    private static CodexThreadActivity UnavailableActivity(Subscription? subscription) =>
        (subscription?.LastActivity ?? CodexThreadActivity.Unknown) with
        {
            Status = CodexMicro.Core.Models.ThreadStatus.Unknown,
            HasPendingQuestion = false,
            ErrorCode = null,
        };

    private void OnDisconnected()
    {
        List<CodexThreadActivityObservation> observations = [];
        lock (_sync)
        {
            ++_connectionGeneration;
            foreach (var pair in _streams)
            {
                // Losing this listener says nothing about the task's outcome.
                observations.Add(new(pair.Key, ++_sequence, UnavailableActivity(pair.Value)));
                pair.Value.Ready.TrySetResult();
            }
            _streams.Clear();
            _resync.Clear();
        }
        Publish(observations);
    }

    private void OnBroadcast(JsonObject message)
    {
        List<CodexThreadActivityObservation> observations = [];
        string[] replies = [];
        string? answeredThread = null;
        Subscription? ready;
        // Decode large snapshots on the IPC worker, outside the lock also used
        // when the UI changes its visible task set.
        using var document = message["params"]?["change"] is JsonObject change
            ? JsonDocument.Parse(change.ToJsonString()) : null;
        lock (_sync)
        {
            ready = ApplyBroadcast(message, document, observations, out answeredThread, out replies);
        }
        Publish(observations);
        if (answeredThread is not null && replies.Length > 0) AnswersAccepted?.Invoke(answeredThread, replies);
        ready?.Ready.TrySetResult();
    }

    private Subscription? ApplyBroadcast(JsonObject message, JsonDocument? document,
        List<CodexThreadActivityObservation> observations, out string? answeredThread, out string[] replies)
    {
        answeredThread = null;
        replies = [];
        if (_disposed) return null;
        if (message.Text("method") == "ipc-connection-reset")
        {
            ++_connectionGeneration;
            // The router can reset subscriptions while this pipe stays open.
            // Retire every old revision before the next roster refresh follows
            // the same task IDs again, even when their owner ID is unchanged.
            foreach (var threadId in _streams.Keys) Invalidate(threadId, observations);
            return null;
        }
        if (message.Text("method") == "thread-stream-following-status-requested" &&
            message["params"]?.Text("hostId") == "local" &&
            message["params"]?.Text("conversationId") is { } requestedId &&
            _wanted.Contains(requestedId) && _streams.ContainsKey(requestedId))
        {
            // Ownership can move without the old client's pipe closing. The
            // new owner explicitly asks followers to register again.
            Invalidate(requestedId, observations);
            return null;
        }
        if (message.Text("method") == "client-status-changed" &&
            message["params"]?.Text("status") == "disconnected")
        {
            foreach (var pair in _streams.Where(pair =>
                pair.Value.Stream.OwnerClientId == message["params"]?.Text("clientId")))
                Invalidate(pair.Key, observations);
            return null;
        }
        if (message.Text("method") != "thread-stream-state-changed" ||
            message["params"]?.Text("hostId") != "local" ||
            message["params"]?.Text("conversationId") is not { } id ||
            !_wanted.Contains(id) || !_streams.TryGetValue(id, out var subscription) ||
            _resync.Contains(id) || subscription.Stream.OwnerClientId != message.Text("sourceClientId")) return null;
        var stream = subscription.Stream;
        if (message["version"] is not JsonValue version || !version.TryGetValue<int>(out var number) ||
            number != 11 || document is null)
        {
            Invalidate(id, observations);
            return null;
        }
        if (!IsValidChange(document.RootElement))
        {
            Invalidate(id, observations);
            return null;
        }
        var result = stream.ApplyChange(document.RootElement);
        var activity = stream.Activity.Current;
        if (result.RequiresSnapshot || !stream.Activity.IsValid)
        {
            Invalidate(id, observations);
            return null;
        }
        if (!result.Applied)
        {
            // Repeating following=true asks the owner for a full snapshot. An
            // unchanged revision confirms liveness without replaying state.
            if (document.RootElement.GetProperty("type").GetString() == "snapshot" &&
                document.RootElement.GetProperty("revision").GetInt64() == stream.Revision)
            {
                subscription.LastMessageAt = Stopwatch.GetTimestamp();
                return subscription;
            }
            return null;
        }
        subscription.LastMessageAt = Stopwatch.GetTimestamp();
        if (activity != subscription.LastActivity)
        {
            subscription.LastActivity = activity;
            observations.Add(new(id, ++_sequence, activity));
        }
        answeredThread = id;
        replies = stream.QuestionAnswers.DrainAcceptedReplies();
        return subscription;
    }

    private static bool IsValidChange(JsonElement change)
    {
        if (!change.TryGetProperty("type", out var type) || type.ValueKind != JsonValueKind.String ||
            !change.TryGetProperty("revision", out var revision) || revision.ValueKind != JsonValueKind.Number ||
            !revision.TryGetInt64(out var number) || number < 0)
            return false;
        if (type.GetString() == "snapshot")
            return change.TryGetProperty("conversationState", out var state) && state.ValueKind == JsonValueKind.Object;
        if (type.GetString() != "patches" || !change.TryGetProperty("baseRevision", out var baseline) ||
            baseline.ValueKind != JsonValueKind.Number || !baseline.TryGetInt64(out _) ||
            !change.TryGetProperty("patches", out var patches) || patches.ValueKind != JsonValueKind.Array) return false;
        return patches.EnumerateArray().All(patch => patch.ValueKind == JsonValueKind.Object &&
            patch.TryGetProperty("op", out var operation) && operation.ValueKind == JsonValueKind.String &&
            operation.GetString() is "add" or "replace" or "remove" &&
            CodexThreadModelStateAccumulator.TryReadPatchPath(patch, out _) &&
            (operation.GetString() == "remove" || patch.TryGetProperty("value", out _)));
    }

    private static bool IsUnavailable(Exception error) => error is IOException or TimeoutException or
        OperationCanceledException or ObjectDisposedException or InvalidOperationException;

    public void Dispose() => _ = DisposeAsync();

    public ValueTask DisposeAsync()
    {
        lock (_sync)
        {
            if (_dispose is not null) return new(_dispose);
            _disposed = true;
            _lifetime.Cancel();
            var refresh = _refresh;
            return new(_dispose = Task.Run(() => DisposeCoreAsync(refresh)));
        }
    }

    private async Task DisposeCoreAsync(Task? refresh)
    {
        OnDisconnected();
        if (refresh is not null) await refresh.ConfigureAwait(false);
        _peer.Broadcast -= OnBroadcast;
        _peer.Disconnected -= OnDisconnected;
        await _peer.DisposeAsync().ConfigureAwait(false);
        _lifetime.Dispose();
    }
}
