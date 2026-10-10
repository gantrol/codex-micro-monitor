using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using AgentController.Adapters.Codex.Windows;
using CodexMicro.Control;
using CodexMicro.Codex;
using CodexMicro.Desktop.Services;
using CodexMicro.Protocol;

namespace CodexMicro.Desktop.Tests;

// Replaces external processes only. No product policy or private field is mocked.
internal sealed class BehaviorAcceptanceRig : IAsyncDisposable
{
    private readonly CancellationTokenSource _lifetime = new();
    private readonly NamedPipeServerStream? _desktop;
    private readonly NamedPipeServerStream _observationDesktop;
    private readonly string _observationPipe = "micro-observer-" + Guid.NewGuid().ToString("N");
    private readonly SemaphoreSlim _desktopWrites = new(1);
    private readonly SemaphoreSlim _observationWrites = new(1);
    private readonly Task _server;
    private readonly ConcurrentQueue<JsonObject> _desktopRequests = new();
    private readonly ConcurrentQueue<string> _openedUris = new();
    private readonly SyntheticUiDesktop _uiDesktop = new();
    private readonly CodexUiController _uiController;
    private readonly KeypadController _controller;
    private string _turnStatus = "inProgress";
    private bool _ownerAvailable = true;
    private string _ownerClientId = "owner";
    private long _revision = 1;
    private const string ThreadId = "01000000-0000-0000-0000-000000000001";
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "micro-acceptance-" + Guid.NewGuid().ToString("N"));
    internal IMicroTransport Transport { get; }
    internal static bool Legacy => false;

    internal BehaviorAcceptanceRig(string mode, string? binding, string slotId = "ACT06")
    {
        Directory.CreateDirectory(_directory);
        _uiController = new(_uiDesktop);
        var pipe = "micro-acceptance-" + Guid.NewGuid().ToString("N");
        {
            _desktop = new(pipe, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
            _observationDesktop = new(_observationPipe, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
            _server = Task.WhenAll(ServeDesktopAsync(_desktop, _desktopWrites),
                ServeDesktopAsync(_observationDesktop, _observationWrites));
            _controller = new KeypadController(new CodexPeerClient(pipe),
                (method, _, _) => method == "collaborationMode/list"
                    ? Task.FromResult<JsonNode>(JsonSerializer.SerializeToNode(new { data = new[] { new { mode = "plan" }, new { mode = "default" } } })!)
                    : throw new InvalidOperationException("This dispatch lane does not provide a model catalog"),
                uri => _openedUris.Enqueue(uri));
            Transport = new SoftwareMicroTransport(_controller, _uiController);
        }
        var slots = CodexMicroLayoutObserver.DefaultSlots.ToDictionary();
        if (binding is not null)
            slots[slotId] = binding == "skill"
                ? new("APPS", null, new("skill", "fixture-skill", Path.Combine(_directory, "SKILL.md")))
                : new("DIFF", binding);
        Transport.CaptureContext = () => new(ThreadId,
            new Dictionary<string, string>(), new(slots, mode, new Dictionary<string, string>(), "synthetic"),
            MicroProfileSettings.CreateTransient().Current);
    }

    internal async Task ConnectAsync()
    {
        await File.WriteAllTextAsync(Path.Combine(_directory, "SKILL.md"), "# Fixture skill", _lifetime.Token);
        await Transport.RecoverCodexLinkAsync();
    }

    internal IReadOnlyList<JsonObject> DesktopRequests => _desktopRequests.ToArray();

    internal Task<JsonNode> ReadDesktopStateAsync() => _controller.ExecuteAsync(
        "get_keypad_state", new() { ["thread_id"] = ThreadId });

    internal CodexDesktopConnection CreateActivityConnection() => new(_observationPipe);

    internal async Task RestartOwnerAsync()
    {
        _ownerAvailable = false;
        _turnStatus = "interrupted";
        var previousOwner = _ownerClientId;
        _ownerClientId = "restarted-owner";
        Interlocked.Exchange(ref _revision, 1);
        await SendAsync(_observationDesktop, _observationWrites, new
        {
            type = "broadcast", method = "client-status-changed", version = 1,
            @params = new { clientId = previousOwner, status = "disconnected" },
        });
    }

    internal void RestoreIdleOwner() => _ownerAvailable = true;

    internal async Task ResumeTaskAsync()
    {
        _turnStatus = "inProgress";
        var before = Interlocked.Read(ref _revision);
        Interlocked.Increment(ref _revision);
        await PublishRuntimeAsync(before, "active");
    }

    private Task PublishRuntimeAsync(long before, string runtime) => _observationDesktop.IsConnected
        ? SendAsync(_observationDesktop, _observationWrites, new
        {
            type = "broadcast", method = "thread-stream-state-changed", version = 11, sourceClientId = _ownerClientId,
            @params = new { hostId = "local", conversationId = ThreadId, change = new
            {
                type = "patches", baseRevision = before, revision = before + 1,
                patches = new[] { new { op = "replace", path = "/threadRuntimeStatus/type", value = runtime } },
            } },
        }) : Task.CompletedTask;

    internal bool SawControlInput(string gesture, string? binding)
    {
        var expectedUiInput = binding == "skill" ? $"skill:fixture-skill:{Path.Combine(_directory, "SKILL.md")}" : gesture switch
        {
            "ACT12" => "submit",
            "ENC" => "composer-choice",
            "wheel+" => "scroll-up",
            "wheel-" => "scroll-down",
            "down" => "sidebar",
            "left" => "history-back",
            "right" => "history-forward",
            _ => null,
        };
        if (expectedUiInput is not null)
            return _uiDesktop.Inputs.SequenceEqual([expectedUiInput]) && _desktopRequests.IsEmpty;
        if (binding == "toggleReviewTab")
            return _openedUris.Count(uri => uri == $"codex://threads/{ThreadId}?view=review") == 1;
        if (gesture == "up")
            return _desktopRequests.Any(request => request["method"]?.GetValue<string>() == "thread-follower-update-thread-settings" &&
                request["params"]?["conversationId"]?.GetValue<string>() == ThreadId &&
                request["params"]?["threadSettings"]?["collaborationMode"]?["mode"]?.GetValue<string>() == "plan");
        if (binding != "turn.cancel")
            throw new InvalidOperationException("FIXTURE GAP: model the new desktop command before accepting its dispatch");
        return _desktopRequests.Any(request =>
            request["method"]?.GetValue<string>() == "thread-follower-interrupt-turn" &&
            request["params"]?["conversationId"]?.GetValue<string>() == ThreadId &&
            request["params"]?["expectedTurnId"]?.GetValue<string>() == "fixture-turn" &&
            request["params"]?["mode"]?.GetValue<string>() == "user-stop");
    }

    private async Task ServeDesktopAsync(NamedPipeServerStream desktop, SemaphoreSlim writes)
    {
        try
        {
            var token = _lifetime.Token;
            while (!token.IsCancellationRequested)
            {
                await desktop.WaitForConnectionAsync(token);
                try { await ServeConnectionAsync(desktop, writes, token); }
                catch (IOException) when (!token.IsCancellationRequested) { }
                finally { if (!token.IsCancellationRequested) desktop.Disconnect(); }
            }
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException) { }
    }

    private async Task ServeConnectionAsync(NamedPipeServerStream desktop, SemaphoreSlim writes, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            var header = new byte[4];
            await desktop.ReadExactlyAsync(header, token);
            var bytes = new byte[BinaryPrimitives.ReadInt32LittleEndian(header)];
            await desktop.ReadExactlyAsync(bytes, token);
            var request = JsonNode.Parse(bytes)!.AsObject();
            var method = request["method"]!.GetValue<string>();
            if (request["type"]?.GetValue<string>() == "broadcast")
            {
                if (_ownerAvailable && method == "thread-stream-following-changed" && request["params"]?["following"]?.GetValue<bool>() == true)
                    await SendAsync(desktop, writes, new
                    {
                        type = "broadcast", method = "thread-stream-state-changed", version = 11, sourceClientId = _ownerClientId,
                        @params = new
                        {
                            hostId = "local", conversationId = ThreadId,
                            change = new { type = "snapshot", revision = Interlocked.Read(ref _revision), conversationState = new
                            {
                                threadRuntimeStatus = new { type = _turnStatus == "inProgress" ? "active" : "idle", activeFlags = Array.Empty<string>() },
                                requests = Array.Empty<object>(),
                                latestModel = "fixture-model", latestReasoningEffort = "medium",
                                latestCollaborationMode = new { mode = "default", settings = new { model = "fixture-model", reasoning_effort = "medium", developer_instructions = (string?)null } },
                                turns = new[] { new { turnId = "fixture-turn", status = _turnStatus, items = Array.Empty<object>() } },
                            } },
                        },
                    });
                continue;
            }
            if (request["type"]?.GetValue<string>() != "request") continue;
            var stop = method == "thread-follower-interrupt-turn" &&
                request["params"]?["conversationId"]?.GetValue<string>() == ThreadId &&
                request["params"]?["expectedTurnId"]?.GetValue<string>() == "fixture-turn" &&
                request["params"]?["mode"]?.GetValue<string>() == "user-stop";
            var supported = method is "initialize" or "thread-owner-discovery" || stop ||
                method == "thread-follower-update-thread-settings" &&
                request["params"]?["threadSettings"]?["collaborationMode"]?["mode"]?.GetValue<string>() == "plan";
            var ownerMissing = method == "thread-owner-discovery" && !_ownerAvailable;
            if (ownerMissing) supported = false;
            if (method is not ("initialize" or "thread-owner-discovery")) _desktopRequests.Enqueue(request);
            var before = Interlocked.Read(ref _revision);
            if (stop) { _turnStatus = "interrupted"; Interlocked.Increment(ref _revision); }
            // Only modeled operations receive an acknowledgement; unknown methods identify a fixture gap.
            await SendAsync(desktop, writes, new
            {
                type = "response", requestId = request["requestId"]!.GetValue<string>(), method,
                resultType = supported ? "success" : "error", handledByClientId = _ownerClientId,
                result = new { clientId = "isolated-desktop-client", ok = true, applied = supported },
                error = ownerMissing ? "no-client-found" : "FIXTURE GAP: " + method,
            });
            if (stop) await PublishRuntimeAsync(before, "idle");
        }
    }

    private async Task SendAsync(NamedPipeServerStream desktop, SemaphoreSlim writes, object response)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(response);
        var header = new byte[4];
        BinaryPrimitives.WriteInt32LittleEndian(header, bytes.Length);
        await writes.WaitAsync(_lifetime.Token);
        try
        {
            await desktop.WriteAsync(header, _lifetime.Token);
            await desktop.WriteAsync(bytes, _lifetime.Token);
            await desktop.FlushAsync(_lifetime.Token);
        }
        finally { writes.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        await Transport.DisposeAsync();
        _uiController.Dispose();
        _lifetime.Cancel();
        _desktop?.Dispose();
        _observationDesktop.Dispose();
        await _server;
        _desktopWrites.Dispose();
        _observationWrites.Dispose();
        _lifetime.Dispose();
        // Only the explicitly created synthetic directory can be removed.
        var root = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!Path.GetFullPath(_directory).StartsWith(root, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Unexpected fixture directory");
        Directory.Delete(_directory, recursive: true);
    }

    // Only the operating-system observation/mutation boundary is synthetic.
    // The real controller must both dispatch once and observe the resulting state.
    private sealed class SyntheticUiDesktop : ICodexUiDesktop, ICodexUiSession
    {
        internal ConcurrentQueue<string> Inputs { get; } = new();
        private UiState _state = new(
            "fixture-chat", Node("composer", UiRole.Editor) with { Text = "fixture prompt" },
            Node("send"), Node("sidebar") with { Name = "Show sidebar" },
            Node("scroller", UiRole.List) with { ScrollPercent = 50 },
            [Node("choice") with { Focused = true, Toggled = false }], [], false,
            HistoryBack: Node("back"), HistoryForward: Node("forward"));

        private static UiNode Node(string id, UiRole role = UiRole.Button) =>
            new(id, null, role, id, "fixture", new Rect(0, 0, 100, 30), Invokable: true);

        public bool IsCurrent => true;
        public ICodexUiSession Capture() => this;
        public UiState Read() => _state;
        public void Dispose() { }

        public void Invoke(string id)
        {
            switch (id)
            {
                case "send":
                    Inputs.Enqueue("submit");
                    _state = _state with { Composer = _state.Composer! with { Text = "" }, Busy = true };
                    break;
                case "sidebar":
                    Inputs.Enqueue("sidebar");
                    _state = _state with { Sidebar = _state.Sidebar! with { Name = "Hide sidebar" } };
                    break;
                case "choice":
                    Inputs.Enqueue("composer-choice");
                    _state = _state with { ComposerControls = [_state.ComposerControls[0] with { Toggled = true }] };
                    break;
                default:
                    throw new InvalidOperationException($"Unmodeled UI invocation: {id}");
            }
        }

        public void Focus(string id) => throw new InvalidOperationException($"Unmodeled focus: {id}");

        public void Scroll(string id, CodexUiOperation operation)
        {
            if (id != "scroller" || operation is not (CodexUiOperation.ScrollUp or CodexUiOperation.ScrollDown))
                throw new InvalidOperationException("Unmodeled scroll");
            var up = operation == CodexUiOperation.ScrollUp;
            Inputs.Enqueue(up ? "scroll-up" : "scroll-down");
            _state = _state with { Scroller = _state.Scroller! with { ScrollPercent = up ? 40 : 60 } };
        }

        public void Navigate(bool forward)
        {
            Inputs.Enqueue(forward ? "history-forward" : "history-back");
            _state = _state with { Route = forward ? "next-chat" : "previous-chat" };
        }

        public bool InsertSkill(string composerId, string name, string path, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            if (composerId != "composer") throw new InvalidOperationException("Unexpected composer");
            Inputs.Enqueue($"skill:{name}:{path}");
            return true;
        }
    }

}
