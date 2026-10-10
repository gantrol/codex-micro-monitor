using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using CodexMicro.Codex;
using CodexMicro.Core.Models;
using CodexMicro.Desktop.Services;
using Xunit;

namespace CodexMicro.Desktop.Tests;

[Trait("Scope", "TaskLighting"), Trait("Layer", "Component")]
public sealed class TaskLightingStreamTests
{
    [Theory]
    [InlineData("active", null, ThreadStatus.Thinking, false)]
    [InlineData("active", "waitingOnApproval", ThreadStatus.RequiresInput, false)]
    [InlineData("active", "waitingOnUserInput", ThreadStatus.Thinking, true)]
    [InlineData("idle", "waitingOnUserInput", ThreadStatus.Idle, false)]
    [InlineData("systemError", null, ThreadStatus.Error, false)]
    [InlineData("unknown", null, ThreadStatus.Unknown, false)]
    public void RuntimeOverridesHistoricalInProgressTurns(
        string type, string? flag, ThreadStatus expected, bool question)
    {
        var stream = new CodexThreadModelStateAccumulator(TaskLightingFixture.ThreadId, "owner");
        Apply(stream, new { type = "snapshot", revision = 1, conversationState = new
        {
            threadRuntimeStatus = new { type, activeFlags = flag is null ? Array.Empty<string>() : [flag] },
            turns = new[] { new { turnId = "old-turn", status = "inProgress" } },
        } });
        Assert.Equal(new(expected, question), stream.Activity.Current);
    }

    [Fact]
    public void NestedFlagsAndRequestsPatchesPreserveAttentionUntilTheyAreRemoved()
    {
        var stream = new CodexThreadModelStateAccumulator(TaskLightingFixture.ThreadId, "owner");
        Apply(stream, Snapshot("active"));
        Patch(stream, 1, new { op = "add", path = "/threadRuntimeStatus/activeFlags/0", value = "waitingOnApproval" });
        Assert.Equal(ThreadStatus.RequiresInput, stream.Activity.Current.Status);
        Patch(stream, 2, new { op = "remove", path = "/threadRuntimeStatus/activeFlags/0" });
        Assert.Equal(ThreadStatus.Thinking, stream.Activity.Current.Status);
        Patch(stream, 3, new { op = "add", path = new object[] { "requests", 0 }, value = new { method = "item/tool/requestUserInput" } });
        Assert.True(stream.Activity.Current.HasPendingQuestion);
        Patch(stream, 4, new { op = "replace", path = new object[] { "requests", 0, "method" }, value = "item/fileChange/requestApproval" });
        Assert.Equal(ThreadStatus.RequiresInput, stream.Activity.Current.Status);
        Patch(stream, 5, new { op = "replace", path = "/requests/length", value = 0 });
        Assert.Equal(new(ThreadStatus.Thinking), stream.Activity.Current);
        Patch(stream, 6, new { op = "replace", path = "/threadRuntimeStatus/type", value = "idle" });
        Assert.Equal(new(ThreadStatus.Idle), stream.Activity.Current);
        Apply(stream, Snapshot("active", revision: 1));
        Assert.Equal(ThreadStatus.Idle, stream.Activity.Current.Status);
        Patch(stream, 7, new { op = "remove", path = "/threadRuntimeStatus" });
        Assert.Equal(ThreadStatus.Unknown, stream.Activity.Current.Status);
    }

    [Fact]
    public async Task StopDisconnectAndOwnerChangeCannotLeaveOrRestoreBlueFromOldEvents()
    {
        await using var fixture = await TaskLightingFixture.CreateAsync();
        var monitor = fixture.CreateMonitor();
        var peer = new ActivityPeer();
        await using var observer = new SoftwareThreadObserver(peer);
        var observations = new List<CodexThreadActivityObservation>();
        observer.ActivityChanged += observation => { observations.Add(observation); monitor.ObserveActivity(observation); };
        await monitor.ReadAsync(CancellationToken.None);
        await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
        Assert.Equal(ThreadStatus.Thinking, await Status());

        peer.Emit(new { type = "patches", baseRevision = 1, revision = 2, patches = new[]
            { new { op = "replace", path = "/threadRuntimeStatus/type", value = "idle" } } });
        Assert.Equal(ThreadStatus.Idle, await Status());
        peer.Emit(Snapshot("active", revision: 1));
        Assert.Equal(ThreadStatus.Idle, await Status());
        peer.Emit(Snapshot("active", revision: 3));
        Assert.Equal(ThreadStatus.Thinking, await Status());

        // A missing patch invalidates the complete stream until rediscovery.
        peer.Emit(new { type = "patches", baseRevision = 4, revision = 5, patches = Array.Empty<object>() });
        Assert.Equal(ThreadStatus.Unknown, await Status());
        peer.Emit(Snapshot("active", revision: 6));
        Assert.Equal(ThreadStatus.Unknown, await Status());
        await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
        Assert.Equal(ThreadStatus.Thinking, await Status());

        peer.OwnerDisconnected();
        Assert.Equal(ThreadStatus.Unknown, await Status());
        peer.Owner = "replacement-owner";
        peer.Runtime = "idle";
        await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
        peer.Emit(Snapshot("active", revision: 100), owner: "owner");
        Assert.Equal(ThreadStatus.Idle, await Status());
        peer.Disconnect();
        Assert.Equal(ThreadStatus.Unknown, await Status());
        // Delivery from a previously queued UI callback also cannot resurrect blue.
        monitor.ObserveActivity(observations.First());
        Assert.Equal(ThreadStatus.Unknown, await Status());
        await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
        Assert.Equal(ThreadStatus.Idle, await Status());
        peer.Emit(Snapshot("active", revision: 2));
        Assert.Equal(ThreadStatus.Thinking, await Status());
        await observer.RefreshAsync([]);
        Assert.Empty(peer.Followed);
        Assert.Equal(ThreadStatus.Unknown, await Status());

        async Task<ThreadStatus> Status() => Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks).Status;
    }

    [Fact]
    public async Task UnavailableOwnerDoesNotBlockOtherTasksOrLeaveSubscriptionsAfterDispose()
    {
        var peer = new ActivityPeer { MissingThread = Guid.NewGuid().ToString() };
        var observer = new SoftwareThreadObserver(peer);
        var observed = new TaskCompletionSource<CodexThreadActivityObservation>(TaskCreationOptions.RunContinuationsAsynchronously);
        observer.ActivityChanged += activity => { if (activity.Activity.Status == ThreadStatus.Thinking) observed.TrySetResult(activity); };
        await observer.RefreshAsync([peer.MissingThread, TaskLightingFixture.ThreadId]);
        Assert.Equal(TaskLightingFixture.ThreadId, (await observed.Task.WaitAsync(TimeSpan.FromSeconds(3))).ThreadId);
        await observer.DisposeAsync();
        Assert.True(peer.Disposed);
        Assert.Empty(peer.Followed);
        await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
        Assert.Empty(peer.Followed);
    }

    [Fact]
    public async Task MonitorColdStartWithoutAnOwnerDoesNotInventATaskError()
    {
        await using var fixture = await TaskLightingFixture.CreateAsync();
        var original = await File.ReadAllTextAsync(fixture.RolloutPath);
        for (var launch = 0; launch < 2; launch++)
        {
            var monitor = fixture.CreateMonitor();
            var peer = new ActivityPeer { MissingThread = TaskLightingFixture.ThreadId };
            await using var observer = new SoftwareThreadObserver(peer);
            observer.ActivityChanged += observation => monitor.ObserveActivity(observation);
            // Exercise discovery both before and after the initial file read.
            if (launch == 0) await monitor.ReadAsync(CancellationToken.None);
            await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
            for (var poll = 0; poll < 2; poll++)
            {
                var task = Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks);
                Assert.Equal(ThreadStatus.Unknown, task.Status);
                Assert.Null(task.ErrorCode);
                Assert.False(task.HasPendingQuestion);
                Assert.Equal(task, Assert.Single((await monitor.ReadPendingQuestionsAsync(CancellationToken.None))!.Tasks));
            }
            // Finding an idle owner later must settle the state immediately;
            // discovery failure is not a sticky task failure to acknowledge.
            peer.MissingThread = null;
            peer.Runtime = "idle";
            await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
            var recovered = Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks);
            Assert.Equal(ThreadStatus.Idle, recovered.Status);
            Assert.Null(recovered.ErrorCode);
        }
        Assert.Equal(original, await File.ReadAllTextAsync(fixture.RolloutPath));
    }

    [Theory]
    [InlineData("task_complete", null, ThreadStatus.Idle)]
    [InlineData("turn_aborted", null, ThreadStatus.Idle)]
    [InlineData("task_complete", "server_overloaded", ThreadStatus.Error)]
    public async Task ExplicitTerminalResultRemainsAuthoritativeWhenObserverDisconnects(string terminal, string? code, ThreadStatus expected)
    {
        await using var fixture = await TaskLightingFixture.CreateAsync();
        var monitor = fixture.CreateMonitor();
        var peer = new ActivityPeer();
        await using var observer = new SoftwareThreadObserver(peer);
        observer.ActivityChanged += observation => monitor.ObserveActivity(observation);
        await monitor.ReadAsync(CancellationToken.None);
        await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
        peer.Disconnect();
        var unavailable = Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks);
        Assert.Equal(ThreadStatus.Unknown, unavailable.Status);
        Assert.Null(unavailable.ErrorCode);
        await fixture.AppendAsync(new { type = terminal, error = code is null ? null : new { codex_error_info = code } });
        var ended = Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks);
        Assert.Equal(expected, ended.Status);
        Assert.Equal(code, ended.ErrorCode);
    }

    [Fact]
    public async Task MicroConnectionLossDoesNotBecomeATaskErrorAndResubscribesToTheSameOwner()
    {
        await using var fixture = await TaskLightingFixture.CreateAsync();
        var monitor = fixture.CreateMonitor();
        var peer = new ActivityPeer();
        await using var observer = new SoftwareThreadObserver(peer);
        observer.ActivityChanged += observation => monitor.ObserveActivity(observation);
        await monitor.ReadAsync(CancellationToken.None);
        await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
        for (var reconnect = 0; reconnect < 2; reconnect++)
        {
            Assert.Equal(ThreadStatus.Thinking, Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks).Status);
            peer.Disconnect(); // Only Micro's link closes; the owner keeps running.
            var unavailable = Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks);
            Assert.Equal(ThreadStatus.Unknown, unavailable.Status);
            Assert.Null(unavailable.ErrorCode);
            Assert.Equal("owner", peer.Owner);
            Assert.Equal("active", peer.Runtime);
            await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
        }
        Assert.Equal(ThreadStatus.Thinking, Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks).Status);
    }

    [Fact]
    public async Task LosingIdleOwnerDoesNotTurnAnAlreadyStoppedTaskIntoAnError()
    {
        await using var fixture = await TaskLightingFixture.CreateAsync();
        var monitor = fixture.CreateMonitor();
        var peer = new ActivityPeer { Runtime = "idle" };
        await using var observer = new SoftwareThreadObserver(peer);
        observer.ActivityChanged += observation => monitor.ObserveActivity(observation);
        await monitor.ReadAsync(CancellationToken.None);
        await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
        peer.OwnerDisconnected();
        peer.MissingThread = TaskLightingFixture.ThreadId;
        for (var poll = 0; poll < 3; poll++)
        {
            await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
            var task = Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks);
            Assert.Equal(ThreadStatus.Unknown, task.Status);
            Assert.Null(task.ErrorCode);
        }
    }

    [Theory]
    [InlineData("""{"type":"snapshot","revision":"broken","conversationState":{}}""")]
    [InlineData("""{"type":"patches","baseRevision":1,"revision":2,"patches":[{"op":"replace","value":"idle"}]}""")]
    [InlineData("""{"type":"patches","baseRevision":1,"revision":2,"patches":[{"op":"replace","path":"/threadRuntimeStatus/activeFlags/3","value":"waitingOnApproval"}]}""")]
    [InlineData("""{"type":"patches","baseRevision":1,"revision":2,"patches":[{"op":"replace","path":"/threadRuntimeStatus/activeFlags","value":"broken"}]}""")]
    public async Task MalformedRuntimeUpdatesWithdrawRunningState(string json)
    {
        var peer = new ActivityPeer();
        await using var observer = new SoftwareThreadObserver(peer);
        var latest = CodexThreadActivity.Unknown;
        observer.ActivityChanged += observation => latest = observation.Activity;
        await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
        Assert.Equal(ThreadStatus.Thinking, latest.Status);
        peer.Emit(JsonNode.Parse(json)!);
        Assert.Equal(ThreadStatus.Unknown, latest.Status);
    }

    private static object Snapshot(string type, int revision = 1) => new
    {
        type = "snapshot", revision, conversationState = new
        {
            threadRuntimeStatus = new { type, activeFlags = Array.Empty<string>() }, requests = Array.Empty<object>(),
        },
    };

    private static void Apply(CodexThreadModelStateAccumulator stream, object change)
    {
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(change));
        stream.ApplyChange(document.RootElement);
    }

    private static void Patch(CodexThreadModelStateAccumulator stream, int revision, object patch) =>
        Apply(stream, new { type = "patches", baseRevision = revision, revision = revision + 1, patches = new[] { patch } });

    private sealed class ActivityPeer : ICodexDesktopConnection
    {
        public event Action<JsonObject>? Broadcast;
        public event Action? Disconnected;
        internal string Owner = "owner";
        internal string Runtime = "active";
        internal string? MissingThread;
        internal bool Disposed;
        internal HashSet<string> Followed { get; } = [];
        public Task ConnectAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task<JsonObject> RequestAsync(string method, int version, object parameters, string? target, CancellationToken token)
        {
            var id = JsonSerializer.SerializeToNode(parameters)!["conversationId"]!.GetValue<string>();
            return id == MissingThread ? Task.FromException<JsonObject>(new IOException("no-client-found"))
                : Task.FromResult(new JsonObject { ["handledByClientId"] = Owner });
        }
        public Task FollowAsync(string id, string owner, bool following, CancellationToken token)
        {
            lock (Followed) { if (following) Followed.Add(id); else Followed.Remove(id); }
            if (following) Emit(Snapshot(Runtime), id);
            return Task.CompletedTask;
        }
        internal void Emit(object change, string id = TaskLightingFixture.ThreadId, string? owner = null) =>
            Broadcast?.Invoke(JsonSerializer.SerializeToNode(new
            {
                method = "thread-stream-state-changed", version = 11, sourceClientId = owner ?? Owner,
                @params = new { hostId = "local", conversationId = id, change },
            })!.AsObject());
        internal void OwnerDisconnected() => Broadcast?.Invoke(JsonSerializer.SerializeToNode(new
        {
            method = "client-status-changed", @params = new { status = "disconnected", clientId = Owner },
        })!.AsObject());
        internal void Disconnect() { Followed.Clear(); Disconnected?.Invoke(); }
        public ValueTask DisposeAsync() { Disposed = true; Disconnect(); return ValueTask.CompletedTask; }
    }
}
