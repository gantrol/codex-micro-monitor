using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using CodexMicro.Desktop.Services;

namespace CodexMicro.Codex;

// Each visible conversation owns its pipe, receive worker and subscription.
// A slow or broken snapshot withdraws only that conversation's observation.
internal sealed class SoftwareThreadObserver : IDisposable, IAsyncDisposable
{
    private sealed class Subscription(string id, ICodexDesktopConnection peer)
    {
        internal string Id { get; } = id;
        internal ICodexDesktopConnection Peer { get; } = peer;
        internal CancellationTokenSource Lifetime { get; } = new();
        internal CodexThreadModelStateAccumulator? Stream;
        internal TaskCompletionSource Ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal CodexThreadActivity? LastActivity;
        internal long LastMessageAt, Generation;
        internal bool Resync;
        internal Task? Refresh;
        internal Action<JsonObject> Broadcast = null!;
        internal Action Disconnected = null!;
    }

    private readonly ICodexDesktopConnection? _providedPeer;
    private readonly object _sync = new();
    private readonly Dictionary<string, Subscription> _streams = new(StringComparer.Ordinal);
    private readonly HashSet<Task> _retiring = [];
    private Task? _dispose;
    private bool _disposed;
    private long _sequence;
    private static readonly TimeSpan ReconfirmInterval = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan ResponseInterval = TimeSpan.FromSeconds(2);

    internal event Action<string, IReadOnlyList<string>>? AnswersAccepted;
    internal event Action<CodexThreadActivityObservation>? ActivityChanged;

    // An explicitly supplied transport belongs to this observer's lifetime.
    // Normal monitoring creates a separate projected connection for each ID.
    internal SoftwareThreadObserver(ICodexDesktopConnection? peer = null) => _providedPeer = peer;

    internal Task RefreshAsync(IEnumerable<string> threadIds)
    {
        List<CodexThreadActivityObservation> observations = [];
        Task[] work;
        lock (_sync)
        {
            if (_disposed) return Task.CompletedTask;
            var wanted = threadIds.Take(CodexTaskMonitorService.Capacity).ToHashSet(StringComparer.Ordinal);
            foreach (var id in _streams.Keys.Where(id => !wanted.Contains(id)).ToArray())
            {
                var removed = _streams[id];
                _streams.Remove(id);
                Invalidate(removed, observations);
                removed.Lifetime.Cancel();
                _retiring.Add(Task.Run(() => RetireAsync(removed)));
            }
            _retiring.RemoveWhere(task => task.IsCompletedSuccessfully);
            foreach (var id in wanted)
            {
                if (!_streams.TryGetValue(id, out var subscription))
                {
                    subscription = new(id, _providedPeer ?? new CodexDesktopConnection(CodexActivityMessageReader.ReadAsync));
                    subscription.Broadcast = message => OnBroadcast(subscription, message);
                    subscription.Disconnected = () => OnDisconnected(subscription);
                    subscription.Peer.Broadcast += subscription.Broadcast;
                    subscription.Peer.Disconnected += subscription.Disconnected;
                    _streams.Add(id, subscription);
                }
                if (subscription.Refresh is null || subscription.Refresh.IsCompleted)
                    subscription.Refresh = Task.Run(() => RefreshSubscriptionAsync(subscription));
            }
            work = _streams.Values.Select(subscription => subscription.Refresh!).Concat(_retiring).ToArray();
        }
        Publish(observations);
        return WaitForRefreshAsync(work);
    }

    private static async Task WaitForRefreshAsync(Task[] work)
    {
        // Leave the roster refreshable while one pipe is receiving a large
        // frame. Its individual operation continues on its own worker.
        try { await Task.WhenAll(work).WaitAsync(ResponseInterval).ConfigureAwait(false); }
        catch (TimeoutException) { }
    }

    private async Task RefreshSubscriptionAsync(Subscription subscription)
    {
        try
        {
            var token = subscription.Lifetime.Token;
            lock (_sync)
            {
                if (!IsCurrent(subscription)) return;
                if (subscription.Stream is not null && !subscription.Resync &&
                    Stopwatch.GetElapsedTime(subscription.LastMessageAt) < ReconfirmInterval) return;
            }
            await subscription.Peer.ConnectAsync(token).ConfigureAwait(false);
            long generation;
            string? previousOwner;
            lock (_sync)
            {
                if (!IsCurrent(subscription)) return;
                generation = subscription.Generation;
                previousOwner = subscription.Stream?.OwnerClientId;
            }
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
            timeout.CancelAfter(ResponseInterval);
            var owner = (await subscription.Peer.RequestAsync("thread-owner-discovery", 1,
                new { hostId = "local", conversationId = subscription.Id }, null, timeout.Token).ConfigureAwait(false))
                .Required("handledByClientId");
            List<CodexThreadActivityObservation> observations = [];
            Task ready;
            lock (_sync)
            {
                if (!IsCurrent(subscription) || generation != subscription.Generation) return;
                if (subscription.Resync || subscription.Stream?.OwnerClientId != owner)
                {
                    if (subscription.Stream is not null) Invalidate(subscription, observations);
                    subscription.Stream = new(subscription.Id, owner);
                }
                subscription.Resync = false;
                subscription.Ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
                ready = subscription.Ready.Task;
            }
            Publish(observations);
            if (previousOwner is not null && previousOwner != owner)
                await subscription.Peer.FollowAsync(subscription.Id, previousOwner, false, timeout.Token).ConfigureAwait(false);
            await subscription.Peer.FollowAsync(subscription.Id, owner, true, timeout.Token).ConfigureAwait(false);
            while (true)
            {
                try { await ready.WaitAsync(ResponseInterval, token).ConfigureAwait(false); break; }
                catch (TimeoutException) when (subscription.Peer is CodexDesktopConnection { IsReceivingFrame: true })
                {
                    // Progress, rather than total snapshot size or duration,
                    // distinguishes an ongoing read from an unavailable owner.
                }
            }
        }
        catch (Exception error) when (IsUnavailable(error))
        {
            List<CodexThreadActivityObservation> observations = [];
            lock (_sync)
                if (IsCurrent(subscription)) Invalidate(subscription, observations);
            Publish(observations);
            SoftwareControlDiagnostics.Write("thread-observer-unavailable", error);
        }
    }

    private bool IsCurrent(Subscription subscription) => !_disposed &&
        _streams.GetValueOrDefault(subscription.Id) == subscription;

    private void Publish(IEnumerable<CodexThreadActivityObservation> observations)
    {
        foreach (var observation in observations) ActivityChanged?.Invoke(observation);
    }

    private void Invalidate(Subscription subscription, List<CodexThreadActivityObservation> observations)
    {
        ++subscription.Generation;
        subscription.LastActivity = (subscription.LastActivity ?? CodexThreadActivity.Unknown) with
        {
            Status = CodexMicro.Core.Models.ThreadStatus.Unknown,
            HasPendingQuestion = false, ErrorCode = null,
        };
        if (!subscription.Resync)
            observations.Add(new(subscription.Id, ++_sequence, subscription.LastActivity.Value));
        subscription.Resync = true;
        subscription.Ready.TrySetResult();
    }

    private void OnDisconnected(Subscription subscription)
    {
        List<CodexThreadActivityObservation> observations = [];
        lock (_sync)
        {
            if (!IsCurrent(subscription)) return;
            Invalidate(subscription, observations);
            subscription.Stream = null;
        }
        Publish(observations);
    }

    private void OnBroadcast(Subscription subscription, JsonObject message)
    {
        if (message["params"]?.Text("conversationId") is { } id && id != subscription.Id) return;
        List<CodexThreadActivityObservation> observations = [];
        TaskCompletionSource? ready;
        string[] replies;
        // Only projected metadata reaches this stage on production pipes.
        using var document = message["params"]?["change"] is JsonObject change
            ? JsonSerializer.SerializeToDocument(change) : null;
        lock (_sync)
            ready = ApplyBroadcast(subscription, message, document, observations, out replies);
        Publish(observations);
        if (replies.Length > 0) AnswersAccepted?.Invoke(subscription.Id, replies);
        ready?.TrySetResult();
    }

    private TaskCompletionSource? ApplyBroadcast(Subscription subscription, JsonObject message,
        JsonDocument? document, List<CodexThreadActivityObservation> observations, out string[] replies)
    {
        replies = [];
        if (!IsCurrent(subscription)) return null;
        if (message.Text("method") == "ipc-connection-reset")
        {
            Invalidate(subscription, observations);
            return null;
        }
        if (message.Text("method") == "thread-stream-following-status-requested" &&
            message["params"]?.Text("hostId") == "local" &&
            message["params"]?.Text("conversationId") == subscription.Id)
        {
            Invalidate(subscription, observations);
            return null;
        }
        if (message.Text("method") == "client-status-changed" &&
            message["params"]?.Text("status") == "disconnected" &&
            subscription.Stream?.OwnerClientId == message["params"]?.Text("clientId"))
        {
            Invalidate(subscription, observations);
            return null;
        }
        if (message.Text("method") != "thread-stream-state-changed" ||
            message["params"]?.Text("hostId") != "local" ||
            message["params"]?.Text("conversationId") != subscription.Id ||
            subscription.Stream is not { } stream || subscription.Resync ||
            stream.OwnerClientId != message.Text("sourceClientId")) return null;
        if (message["version"] is not JsonValue version || !version.TryGetValue<int>(out var number) ||
            number != 11 || document is null || !IsValidChange(document.RootElement))
        {
            Invalidate(subscription, observations);
            return null;
        }
        var result = stream.ApplyChange(document.RootElement);
        var activity = stream.Activity.Current;
        if (result.RequiresSnapshot || !stream.Activity.IsValid)
        {
            Invalidate(subscription, observations);
            return null;
        }
        if (!result.Applied)
        {
            if (document.RootElement.GetProperty("type").GetString() == "snapshot" &&
                document.RootElement.GetProperty("revision").GetInt64() == stream.Revision)
            {
                subscription.LastMessageAt = Stopwatch.GetTimestamp();
                return subscription.Ready;
            }
            return null;
        }
        subscription.LastMessageAt = Stopwatch.GetTimestamp();
        if (activity != subscription.LastActivity)
        {
            subscription.LastActivity = activity;
            observations.Add(new(subscription.Id, ++_sequence, activity));
        }
        replies = stream.QuestionAnswers.DrainAcceptedReplies();
        return subscription.Ready;
    }

    private static bool IsValidChange(JsonElement change)
    {
        if (!change.TryGetProperty("type", out var type) || type.ValueKind != JsonValueKind.String ||
            !change.TryGetProperty("revision", out var revision) || revision.ValueKind != JsonValueKind.Number ||
            !revision.TryGetInt64(out var number) || number < 0) return false;
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
        OperationCanceledException or ObjectDisposedException or InvalidOperationException or JsonException;

    private async Task RetireAsync(Subscription subscription)
    {
        subscription.Peer.Broadcast -= subscription.Broadcast;
        subscription.Peer.Disconnected -= subscription.Disconnected;
        if (_providedPeer is null) await subscription.Peer.DisposeAsync().ConfigureAwait(false);
        if (subscription.Refresh is not null) await subscription.Refresh.ConfigureAwait(false);
        if (_providedPeer is not null && subscription.Stream is { } stream)
        {
            using var timeout = new CancellationTokenSource(ResponseInterval);
            try { await subscription.Peer.FollowAsync(subscription.Id, stream.OwnerClientId, false, timeout.Token).ConfigureAwait(false); }
            catch (Exception error) when (IsUnavailable(error)) { }
        }
        subscription.Lifetime.Dispose();
    }

    public void Dispose() => _ = DisposeAsync();

    public ValueTask DisposeAsync()
    {
        lock (_sync)
        {
            if (_dispose is not null) return new(_dispose);
            _disposed = true;
            List<CodexThreadActivityObservation> observations = [];
            foreach (var subscription in _streams.Values)
            {
                Invalidate(subscription, observations);
                subscription.Lifetime.Cancel();
            }
            var subscriptions = _streams.Values.ToArray();
            _streams.Clear();
            return new(_dispose = Task.Run(async () =>
            {
                Publish(observations);
                await Task.WhenAll(subscriptions.Select(RetireAsync).Concat(_retiring)).ConfigureAwait(false);
                if (_providedPeer is not null) await _providedPeer.DisposeAsync().ConfigureAwait(false);
            }));
        }
    }
}
