using System.Diagnostics;
using System.IO;
using System.Text.Json.Nodes;
using CodexMicro.Desktop.Services;

namespace CodexMicro.Codex;

internal sealed class KeypadController : IAsyncDisposable
{
    private readonly CodexPeerClient _peer;
    private readonly LocalAppServer _catalog = new();
    private readonly Func<string, object, CancellationToken, Task<JsonNode>> _catalogCall;
    private readonly Action<string> _openUri;
    private readonly SemaphoreSlim _gate = new(1);
    private readonly object _snapshotSync = new();
    private TaskCompletionSource<JsonObject>? _snapshot;
    private string? _snapshotThread;
    private string? _snapshotOwner;

    internal KeypadController(CodexPeerClient? peer = null,
        Func<string, object, CancellationToken, Task<JsonNode>>? catalogCall = null,
        Action<string>? openUri = null)
    {
        _peer = peer ?? new();
        _catalogCall = catalogCall ?? _catalog.CallAsync;
        _openUri = openUri ?? OpenUri;
        _peer.Broadcast += OnBroadcast;
        _peer.Disconnected += () => { lock (_snapshotSync) _snapshot?.TrySetException(new IOException("Codex disconnected")); };
    }

    internal Task ConnectAsync(CancellationToken cancellationToken) => _peer.ConnectAsync(cancellationToken);

    internal event Action? Disconnected
    {
        add => _peer.Disconnected += value;
        remove => _peer.Disconnected -= value;
    }

    internal async Task<JsonNode> ExecuteAsync(string tool, JsonObject arguments, CancellationToken cancellationToken = default, Func<Task<bool>>? canApply = null)
    {
        await _gate.WaitAsync(cancellationToken);
        var started = Stopwatch.GetTimestamp();
        var outcome = "acknowledged";
        try
        {
            if (tool == "list_keypad_threads")
            {
                var result = await _catalogCall("thread/list", new { limit = 24, sortKey = "recency_at", sortDirection = "desc", useStateDbOnly = true }, cancellationToken);
                var rows = result["data"]?.AsArray() ?? throw new IOException("Missing thread list");
                return JsonSupport.Node(new { threads = rows.Select(row => new
                {
                    id = row?.Text("id"), title = row?.Text("name") ?? row?.Text("preview"),
                    cwd = row?.Text("cwd"), status = row?["status"]?.DeepClone()
                }) });
            }
            if (tool == "get_keypad_models") return await ModelsAsync(cancellationToken);
            if (tool == "new_keypad_thread")
            {
                await EnsureTargetCurrentAsync();
                _openUri("codex://threads/new");
                return JsonSupport.Node(new { opened = true });
            }

            var threadId = JsonSupport.ThreadId(arguments.Required("thread_id"));
            if (tool is "open_keypad_thread" or "open_keypad_review")
            {
                await EnsureTargetCurrentAsync();
                _openUri("codex://threads/" + Uri.EscapeDataString(threadId) +
                    (tool == "open_keypad_review" ? "?view=review" : ""));
                return JsonSupport.Node(new { opened = true, threadId });
            }
            if (tool == "fork_keypad_thread")
            {
                await EnsureTargetCurrentAsync();
                var fork = await _catalogCall("thread/fork", new { threadId, excludeTurns = true, deferGoalContinuation = true }, cancellationToken);
                var created = JsonSupport.ThreadId(fork["thread"]?.Required("id") ?? throw new IOException("Missing fork ID"));
                string? openError = null;
                try { _openUri("codex://threads/" + Uri.EscapeDataString(created)); }
                catch (Exception error) { openError = error.Message; }
                return JsonSupport.Node(new { threadId = created, forkedFrom = threadId, opened = openError is null, openError });
            }

            await _peer.ConnectAsync(cancellationToken);
            var discovery = await _peer.RequestAsync("thread-owner-discovery", 1, new { hostId = "local", conversationId = threadId }, null, cancellationToken);
            var owner = discovery.Required("handledByClientId");
            var state = await ReadSnapshotAsync(threadId, owner, cancellationToken);
            if (tool == "get_keypad_state") return ProjectState(threadId, state);

            if (tool is "set_keypad_model" or "set_keypad_reasoning" or "set_keypad_fast" or "toggle_keypad_fast" or "toggle_keypad_plan")
            {
                var model = state["latestThreadSettings"]?.Text("model") ?? state.Text("latestModel");
                var effort = EffectiveEffort(state);
                if (arguments.ContainsKey("expected_model") && arguments.Text("expected_model") != model ||
                    arguments.ContainsKey("expected_effort") && arguments.Text("expected_effort") != effort ||
                    arguments.ContainsKey("expected_service_tier") && arguments.Text("expected_service_tier") != state["latestThreadSettings"]?.Text("serviceTier"))
                {
                    SoftwareControlDiagnostics.Write("settings-rejected stale-action");
                    throw new InvalidOperationException("Thread settings changed while the keypad action was pending");
                }
                var settings = new JsonObject();
                if (tool == "toggle_keypad_plan")
                {
                    var currentMode = (state["latestThreadSettings"]?["collaborationMode"] ?? state["latestCollaborationMode"])?.Text("mode");
                    if (currentMode is not ("plan" or "default") || string.IsNullOrWhiteSpace(model))
                        throw new NotSupportedException("This collaboration mode cannot be toggled");
                    var targetMode = currentMode == "plan" ? "default" : "plan";
                    var modes = await _catalogCall("collaborationMode/list", new { }, cancellationToken);
                    if (modes["data"] is not JsonArray available || !available.Any(item => item?.Text("mode") == targetMode))
                        throw new NotSupportedException("The target collaboration mode is unavailable");
                    // Match the desktop picker: null requests the selected mode's default instructions.
                    // Copying the previous mode's instructions would retain Default behavior in Plan.
                    settings["collaborationMode"] = JsonSupport.Node(new
                    {
                        mode = targetMode,
                        settings = new { model, reasoning_effort = effort, developer_instructions = (string?)null },
                    });
                }
                else if (tool is "set_keypad_fast" or "toggle_keypad_fast")
                {
                    var enabled = tool == "toggle_keypad_fast"
                        ? !CodexServiceTier.IsFast(state["latestThreadSettings"]?.Text("serviceTier"))
                        : arguments["enabled"]?.GetValue<bool>() == true;
                    string? fastTier = null;
                    if (enabled)
                    {
                        var catalog = await ModelsAsync(cancellationToken);
                        var definition = catalog["data"]?.AsArray().FirstOrDefault(item => item?.Text("model") == model);
                        fastTier = definition?["serviceTiers"]?.AsArray()
                            .FirstOrDefault(tier => CodexServiceTier.IsFast(tier?.Text("id")))?.Text("id");
                        if (fastTier is null && definition?["additionalSpeedTiers"]?.AsArray()
                            .Any(tier => tier?.GetValue<string>() == "fast") == true) fastTier = "fast";
                        if (fastTier is null) throw new ArgumentException("Fast is unavailable for the current model");
                    }
                    settings["serviceTier"] = fastTier;
                }
                else
                {
                    var targetModel = tool == "set_keypad_model" ? arguments.Required("model") : model ?? throw new IOException("Model is unavailable");
                    var models = await ModelsAsync(cancellationToken);
                    var definition = models["data"]?.AsArray().FirstOrDefault(item => item?.Text("model") == targetModel)
                        ?? throw new ArgumentException("Model is not in the current Codex catalog");
                    var requested = arguments.Text("effort") ?? (tool == "set_keypad_model" ? definition.Text("defaultReasoningEffort") : effort);
                    if (requested is null || definition["supportedReasoningEfforts"] is not JsonArray efforts ||
                        !efforts.Any(item => item?.Text("reasoningEffort") == requested))
                        throw new ArgumentException("Reasoning effort is not supported by this model");
                    if (tool == "set_keypad_model") settings["model"] = targetModel;
                    settings["effort"] = requested;
                }
                // The desktop condition compares the raw fields, not latestThreadSettings.
                // Preserve absent fields: JavaScript distinguishes undefined from null.
                var condition = new JsonObject();
                if (state.ContainsKey("latestModel")) condition["ifModelEquals"] = state["latestModel"]?.DeepClone();
                if (state.ContainsKey("latestReasoningEffort")) condition["ifEffortEquals"] = state["latestReasoningEffort"]?.DeepClone();
                await EnsureTargetCurrentAsync();
                var update = await _peer.RequestAsync("thread-follower-update-thread-settings", 2,
                    new { conversationId = threadId, threadSettings = settings, condition }, owner, cancellationToken);
                if (update["result"]?["applied"]?.GetValue<bool>() != true)
                {
                    SoftwareControlDiagnostics.Write("settings-rejected condition-mismatch");
                    throw new InvalidOperationException("Thread settings changed; read the current state again");
                }
                return JsonSupport.Node(new { applied = true, threadId, settings });
            }
            if (tool == "send_keypad_message")
            {
                var text = arguments.Required("text");
                if (text.Length > 100_000) throw new ArgumentException("Message is too long");
                if (ActiveTurn(state) is not null || state["threadRuntimeStatus"]?.Text("type") == "active" ||
                    state["unconfirmedTurnSubmissions"] is JsonArray submissions && submissions.Any(item => item?["terminal"]?.GetValue<bool>() != true))
                    throw new InvalidOperationException("The selected chat already has an active or unconfirmed turn");
                await EnsureTargetCurrentAsync();
                var sent = await _peer.RequestAsync("thread-follower-start-turn", 2, new
                {
                    conversationId = threadId,
                    turnStart = new
                    {
                        request = new { threadId, input = new[] { new { type = "text", text, text_elements = Array.Empty<object>() } }, clientUserMessageId = Guid.NewGuid().ToString() },
                        context = new { inheritThreadSettings = true }
                    }
                }, owner, cancellationToken);
                return sent["result"]?.DeepClone() ?? new JsonObject();
            }
            if (tool == "stop_keypad_turn")
            {
                var turnId = arguments.Required("turn_id");
                if (ActiveTurn(state) != turnId) throw new InvalidOperationException("The active turn changed");
                await EnsureTargetCurrentAsync();
                var stopped = await _peer.RequestAsync("thread-follower-interrupt-turn", 4,
                    new { conversationId = threadId, mode = "user-stop", expectedTurnId = turnId }, owner, cancellationToken);
                return stopped["result"]?.DeepClone() ?? new JsonObject();
            }
            if (tool == "reply_keypad_approval")
            {
                var requestId = arguments.Required("request_id");
                var decision = arguments.Required("decision");
                if (decision is not ("accept" or "decline")) throw new ArgumentException("Invalid approval decision");
                var pending = state["requests"]?.AsArray().FirstOrDefault(request => RequestId(request) == requestId)
                    ?? throw new InvalidOperationException("The approval request is no longer pending");
                var method = pending.Text("method") switch
                {
                    "item/commandExecution/requestApproval" => "thread-follower-command-approval-decision",
                    "item/fileChange/requestApproval" => "thread-follower-file-approval-decision",
                    _ => throw new InvalidOperationException("Use Codex for this request type")
                };
                await EnsureTargetCurrentAsync();
                var reply = await _peer.RequestAsync(method, 1,
                    new { conversationId = threadId, requestId = pending["id"]?.DeepClone(), decision }, owner, cancellationToken);
                return JsonSupport.Node(new { acknowledged = reply["result"]?["ok"]?.GetValue<bool>() == true, threadId, requestId });
            }
            throw new ArgumentException("Unknown keypad tool");
        }
        catch (Exception error)
        {
            outcome = error.GetType().Name;
            throw;
        }
        finally
        {
            var operation = string.Concat(tool.Where(character => char.IsAsciiLetterOrDigit(character) || character == '_').Take(64));
            SoftwareControlDiagnostics.Write($"operation={operation} outcome={outcome} elapsedMs={Stopwatch.GetElapsedTime(started).TotalMilliseconds:F0}");
            _gate.Release();
        }

        async Task EnsureTargetCurrentAsync()
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (canApply is not null && !await canApply().WaitAsync(cancellationToken))
            {
                SoftwareControlDiagnostics.Write("action-not-sent target-changed");
                throw new InvalidOperationException("The selected Codex chat changed while the keypad action was pending");
            }
            cancellationToken.ThrowIfCancellationRequested();
        }
    }

    private Task<JsonNode> ModelsAsync(CancellationToken cancellationToken) => _catalogCall("model/list", new { limit = 100 }, cancellationToken);

    private async Task<JsonObject> ReadSnapshotAsync(string threadId, string owner, CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_snapshotSync) { _snapshot = completion; _snapshotThread = threadId; _snapshotOwner = owner; }
        try
        {
            await _peer.FollowAsync(threadId, owner, false, cancellationToken);
            await _peer.FollowAsync(threadId, owner, true, cancellationToken);
            return await completion.Task.WaitAsync(TimeSpan.FromSeconds(6), cancellationToken);
        }
        finally
        {
            lock (_snapshotSync) { _snapshot = null; _snapshotThread = null; _snapshotOwner = null; }
            try { await _peer.FollowAsync(threadId, owner, false, CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(1)); }
            catch (Exception error) when (error is IOException or TimeoutException or ObjectDisposedException) { }
        }
    }

    private void OnBroadcast(JsonObject message)
    {
        if (message.Text("method") != "thread-stream-state-changed") return;
        lock (_snapshotSync)
        {
            if (_snapshot is null || message.Text("sourceClientId") != _snapshotOwner ||
                message["params"]?.Text("conversationId") != _snapshotThread) return;
            if (message["version"]?.GetValue<int>() != 11)
            {
                _snapshot.TrySetException(new IOException("Unsupported Codex desktop state protocol"));
                return;
            }
            var change = message["params"]?["change"];
            if (change?.Text("type") == "snapshot" && change["conversationState"] is JsonObject state)
                _snapshot.TrySetResult((JsonObject)state.DeepClone());
        }
    }

    internal static JsonNode ProjectState(string threadId, JsonObject state) => JsonSupport.Node(new
    {
        threadId, title = state.Text("title"),
        model = state["latestThreadSettings"]?.Text("model") ?? state.Text("latestModel"),
        effort = EffectiveEffort(state),
        serviceTier = state["latestThreadSettings"]?.Text("serviceTier"),
        collaborationMode = (state["latestThreadSettings"]?["collaborationMode"] ?? state["latestCollaborationMode"])?.DeepClone(),
        activeTurnId = ActiveTurn(state),
        approvals = state["requests"]?.AsArray().OfType<JsonObject>().Where(request => request.Text("method") is "item/commandExecution/requestApproval" or "item/fileChange/requestApproval")
            .Select(request => new { id = RequestId(request), method = request.Text("method"), details = request["params"]?.DeepClone() }).ToArray()
    });

    private static string? EffectiveEffort(JsonObject state) =>
        state["latestThreadSettings"] is JsonObject settings && settings.ContainsKey("effort")
            ? settings.Text("effort")
            : state.Text("latestReasoningEffort");

    private static string? RequestId(JsonNode? request) => request?["id"] is JsonValue value && value.TryGetValue<string>(out var text) ? text : request?["id"]?.ToJsonString();

    private static string? ActiveTurn(JsonObject state)
    {
        static string? Find(JsonNode? node)
        {
            if (node is JsonObject item)
            {
                if (item.Text("status") == "inProgress" && item.Text("turnId") is { } turn) return turn;
                foreach (var child in item) { var found = Find(child.Value); if (found is not null) return found; }
            }
            else if (node is JsonArray array)
                foreach (var child in array.Reverse()) { var found = Find(child); if (found is not null) return found; }
            return null;
        }
        return Find(state["turnHistory"]) ?? Find(state["turns"]);
    }

    private static void OpenUri(string uri) => Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true })?.Dispose();

    public async ValueTask DisposeAsync()
    {
        try { await _peer.DisposeAsync(); }
        finally { await _catalog.DisposeAsync(); }
    }
}
