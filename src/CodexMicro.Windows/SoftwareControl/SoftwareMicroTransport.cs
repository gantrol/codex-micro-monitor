using System.Diagnostics.CodeAnalysis;
using System.IO;
using System.Text.Json.Nodes;
using CodexMicro.Control;
using CodexMicro.Desktop.Services;
using CodexMicro.Protocol;

namespace CodexMicro.Codex;

internal sealed class SoftwareMicroTransport : IMicroTransport
{
    private readonly KeypadController _controller;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly SemaphoreSlim _actions = new(1);
    private volatile bool _ready;
    private bool _disposed;
    private Task? _shutdown;
    private string? _joystickDirection;
    private static readonly BrokerDriverInfo Info = new(0, 0, 0, 0, 0, "Codex IPC", true);

    public SoftwareMicroTransport(KeypadController? controller = null)
    {
        _controller = controller ?? new();
        _controller.Disconnected += OnDisconnected;
    }
    public event EventHandler<string>? Log;
    public event EventHandler<string>? StateChanged;
    public event EventHandler<SlotLightingSnapshot>? SlotLightingObserved { add { } remove { } }
    public bool UsesSoftwareControl => true;
    public bool IsReady => !_disposed && _ready;
    public bool CodexLinkObserved => IsReady;
    public Func<MicroControlContext>? CaptureContext { private get; set; }
    public Action<string?>? ThreadOpened { private get; set; }
    public Action<string, string?>? ServiceTierApplied { private get; set; }
    public Func<string?, CancellationToken, Task<bool>>? ValidateTargetAsync { private get; set; }

    public void StartConnecting() => _ = Task.Run(ConnectInBackgroundAsync);

    private async Task ConnectInBackgroundAsync()
    {
        try { await RecoverCodexLinkAsync(); }
        catch (Exception error) when (error is IOException or TimeoutException or OperationCanceledException or ObjectDisposedException)
        {
            SoftwareControlDiagnostics.Write("connection-failed", error);
            OnDisconnected();
            Log?.Invoke(this, error.Message);
        }
    }

    public bool TryConnect([NotNullWhen(true)] out BrokerDriverInfo? info, out string error)
    {
        info = IsReady ? Info : null;
        error = IsReady ? string.Empty : "Codex IPC is not connected";
        return info is not null;
    }

    public async Task<BrokerDriverInfo> RecoverCodexLinkAsync()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(6));
        await _controller.ConnectAsync(timeout.Token).ConfigureAwait(false);
        timeout.Token.ThrowIfCancellationRequested();
        _ready = true;
        SoftwareControlDiagnostics.Write("connected");
        StateChanged?.Invoke(this, "ready");
        return Info;
    }

    private void OnDisconnected()
    {
        _ready = false;
        SoftwareControlDiagnostics.Write("disconnected");
        StateChanged?.Invoke(this, "unavailable");
    }

    public Task<MicroSendResult> TapKeyAsync(string key)
    {
        var context = CaptureContext?.Invoke() ?? throw new InvalidOperationException("No keypad context");
        if (context.AgentThreads.TryGetValue(key, out var selected))
            return RunAsync(() => OpenThreadAsync(selected));
        if (key.StartsWith("AG", StringComparison.Ordinal)) return Unsupported("Empty agent slot");
        if (key == "ENC_QUICK" || key == "ENC" && context.Layout.EncoderMode == "reasoning")
            return RunAsync(() => ToggleModelAsync(context));
        if (key == "ENC") return Unsupported("Composer navigation is not implemented by the software controls.");
        if (!context.Layout.Slots.TryGetValue(key, out var binding)) return Unsupported("Unknown control");
        if (binding.Action is { Type: not "command" }) return Unsupported("Composer skill insertion is not implemented by the software controls.");
        return RunAsync(() => ExecuteActionAsync(binding.ResolvedAction, context),
            queue: binding.ResolvedAction == "composer.toggleFastMode");
    }

    public Task<MicroSendResult> SetKeyAsync(string key, bool pressed) => pressed
        ? TapKeyAsync(key)
        : Task.FromResult(Accepted("released"));

    public Task<MicroSendResult> StepEncoderAsync(bool clockwise)
    {
        var context = CaptureContext?.Invoke() ?? throw new InvalidOperationException("No keypad context");
        return context.Layout.EncoderMode == "reasoning"
            ? RunAsync(() => StepReasoningAsync(context, DialDirectionSettings.ToReasoningStep(clockwise)))
            : Unsupported("Composer navigation and scrolling are not implemented by the software controls.");
    }

    public Task<MicroSendResult> OpenCodexMicroSettingsAsync(CancellationToken cancellationToken = default) =>
        Unsupported("Device settings are not implemented by the software controls.");

    public Task<MicroSendResult> SetJoystickStateAsync(double angle, double distance, string direction)
    {
        if (distance < 0.5)
        {
            _joystickDirection = null;
            return Task.FromResult(Accepted("neutral"));
        }
        if (_joystickDirection == direction) return Task.FromResult(Accepted("held"));
        _joystickDirection = direction;
        return MoveJoystickAsync(angle, distance, direction);
    }

    public Task<MicroSendResult> MoveJoystickAsync(double angle, double distance, string direction)
    {
        var context = CaptureContext?.Invoke() ?? throw new InvalidOperationException("No keypad context");
        var normalized = direction.ToLowerInvariant();
        var action = context.Layout.AnalogActions.GetValueOrDefault(normalized) ?? (normalized switch
        {
            "up" => "composer.togglePlanMode", "down" => "toggleSidebar",
            "left" => "navigateBack", "right" => "navigateForward", _ => null,
        });
        if (action is null) return Unsupported("Default joystick navigation is not implemented by the software controls.");
        return RunAsync(() => ExecuteActionAsync(action, context));
    }

    private async Task OpenThreadAsync(string thread)
    {
        await CallAsync("open_keypad_thread", new() { ["thread_id"] = thread });
        ThreadOpened?.Invoke(thread);
    }

    private async Task ExecuteActionAsync(string action, MicroControlContext context)
    {
        if (action == "newTask")
        {
            await CallAsync("new_keypad_thread", new());
            ThreadOpened?.Invoke(null);
            return;
        }
        var supported = action is "forkThread" or "composer.toggleFastMode" or "composer.togglePlanMode" or "toggleReviewTab" or "approval.approve" or "approval.decline"
            or "composer.increaseReasoningEffort" or "composer.decreaseReasoningEffort" or "turn.cancel";
        if (!supported) throw new NotSupportedException($"Software controls do not implement: {action}");
        var thread = RequireThread(context);
        if (action is "toggleReviewTab" or "composer.togglePlanMode")
        {
            await CallAsync(action == "toggleReviewTab" ? "open_keypad_review" : "toggle_keypad_plan",
                new() { ["thread_id"] = thread }, context);
            return;
        }
        if (action == "forkThread")
        {
            var fork = await CallAsync("fork_keypad_thread", new() { ["thread_id"] = thread }, context);
            ThreadOpened?.Invoke(fork.Required("threadId"));
            if (fork.Text("openError") is { } error) Log?.Invoke(this, error);
            return;
        }
        if (action is "composer.increaseReasoningEffort" or "composer.decreaseReasoningEffort")
        {
            await StepReasoningAsync(context, action == "composer.increaseReasoningEffort" ? 1 : -1);
            return;
        }
        if (action == "composer.toggleFastMode")
        {
            var updated = await CallAsync("toggle_keypad_fast", new() { ["thread_id"] = thread }, context);
            ServiceTierApplied?.Invoke(thread, updated["settings"]?.Text("serviceTier"));
            return;
        }
        var state = await StateAsync(thread);
        switch (action)
        {
            case "approval.approve":
            case "approval.decline":
                var approvals = state["approvals"] as JsonArray;
                if (approvals?.Count != 1) throw new InvalidOperationException("Select one specific approval in Codex; multiple or missing approvals are not dispatched.");
                var approval = await CallAsync("reply_keypad_approval", new()
                {
                    ["thread_id"] = thread,
                    ["request_id"] = approvals[0]!.Required("id"),
                    ["decision"] = action == "approval.approve" ? "accept" : "decline"
                }, context);
                if (approval["acknowledged"]?.GetValue<bool>() != true)
                    throw new InvalidOperationException("Codex did not acknowledge the approval decision");
                break;
            case "turn.cancel":
                await CallAsync("stop_keypad_turn", new()
                {
                    ["thread_id"] = thread,
                    ["turn_id"] = state.Text("activeTurnId") ?? throw new InvalidOperationException("No active turn")
                }, context);
                break;
        }
    }

    private async Task ToggleModelAsync(MicroControlContext context)
    {
        var thread = RequireThread(context);
        var state = await StateAsync(thread);
        var sameModel = context.Profile.QuickModelA.Id == context.Profile.QuickModelB.Id;
        var effortA = context.Profile.QuickModelAEffort;
        if (sameModel && effortA is null)
        {
            var models = await CallAsync("get_keypad_models", new());
            effortA = models["data"]?.AsArray().FirstOrDefault(item => item?.Text("model") == context.Profile.QuickModelA.Id)
                ?.Text("defaultReasoningEffort");
        }
        var selectB = state.Text("model") == context.Profile.QuickModelA.Id &&
            (!sameModel || state.Text("effort") == effortA);
        var args = SettingsArguments(thread, state);
        args["model"] = selectB ? context.Profile.QuickModelB.Id : context.Profile.QuickModelA.Id;
        var effort = selectB ? context.Profile.QuickModelBEffort : context.Profile.QuickModelAEffort;
        if (effort is not null) args["effort"] = effort;
        await CallAsync("set_keypad_model", args, context);
    }

    private async Task StepReasoningAsync(MicroControlContext context, int direction)
    {
        var thread = RequireThread(context);
        var state = await StateAsync(thread);
        var models = await CallAsync("get_keypad_models", new());
        var model = models["data"]?.AsArray().FirstOrDefault(item => item?.Text("model") == state.Text("model"))
            ?? throw new InvalidOperationException("Current model is not in the Codex catalog");
        var supported = model["supportedReasoningEfforts"]?.AsArray()
            .Select(item => item?.Text("reasoningEffort")).Where(item => item is not null).ToArray() ?? [];
        var index = Array.IndexOf(supported, state.Text("effort"));
        if (index < 0 || supported.Length == 0) throw new InvalidOperationException("Current reasoning effort is unavailable");
        var next = Math.Clamp(index + direction, 0, supported.Length - 1);
        if (next == index) return;
        var args = SettingsArguments(thread, state);
        args["effort"] = supported[next];
        await CallAsync("set_keypad_reasoning", args, context);
    }

    private static JsonObject SettingsArguments(string thread, JsonNode state) => new()
    {
        ["thread_id"] = thread,
        ["expected_model"] = state.Text("model"),
        ["expected_effort"] = state.Text("effort"),
        ["expected_service_tier"] = state.Text("serviceTier")
    };

    private Task<JsonNode> StateAsync(string thread) => CallAsync("get_keypad_state", new() { ["thread_id"] = thread });
    private async Task<JsonNode> CallAsync(string tool, JsonObject args, MicroControlContext? context = null)
    {
        var result = await _controller.ExecuteAsync(tool, args, _lifetime.Token,
            context is null ? null : async () => !_disposed &&
                (ValidateTargetAsync is not null
                    ? await ValidateTargetAsync(context.ThreadId, _lifetime.Token)
                    : CaptureContext?.Invoke().ThreadId == context.ThreadId));
        if (result["ok"] is JsonValue value && value.TryGetValue<bool>(out var ok) && !ok)
            throw new InvalidOperationException("Codex did not acknowledge the keypad action");
        return result;
    }
    private static string RequireThread(MicroControlContext context) => context.ThreadId is { } thread
        ? JsonSupport.ThreadId(thread) : throw new InvalidOperationException("Select a Codex chat first. A blank draft has no thread ID.");

    private async Task<MicroSendResult> RunAsync(Func<Task> action, bool queue = false)
    {
        if (_disposed) return MicroSendResult.NotSent("The keypad is closed");
        // Reversible Fast presses retain their order; approval and other actions never queue.
        if (!await _actions.WaitAsync(queue ? 6000 : 0))
        {
            SoftwareControlDiagnostics.Write("action-skipped busy");
            return MicroSendResult.NotSent("A keypad action is already pending");
        }
        try
        {
            if (_disposed) return MicroSendResult.NotSent("Keypad is closed");
            if (!IsReady)
            {
                try { await RecoverCodexLinkAsync(); }
                catch (Exception error) when (error is IOException or TimeoutException or OperationCanceledException or ObjectDisposedException)
                {
                    SoftwareControlDiagnostics.Write($"action-not-sent connection={error.GetType().Name}");
                    return MicroSendResult.NotSent("Codex IPC is disconnected");
                }
            }
            await action();
            return Accepted("Codex software request acknowledged");
        }
        catch (NotSupportedException error)
        {
            return MicroSendResult.NotSent(error.Message);
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException)
        {
            return new(MicroSendDisposition.Rejected, 0, 0, 0, error.Message);
        }
        catch (Exception error) when (error is IOException or TimeoutException or OperationCanceledException)
        {
            return new(MicroSendDisposition.OutcomeUnknown, 0, 0, 0, error.Message);
        }
        finally { _actions.Release(); }
    }

    private static MicroSendResult Accepted(string detail) => new(MicroSendDisposition.Accepted, 0, 0, 0, detail);
    private static Task<MicroSendResult> Unsupported(string detail) => Task.FromResult(MicroSendResult.NotSent(detail));

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _ready = false;
        _lifetime.Cancel();
        _controller.Disconnected -= OnDisconnected;
        _shutdown = DisposeControllerAsync();
    }

    public ValueTask DisposeAsync()
    {
        Dispose();
        return new ValueTask(_shutdown ?? Task.CompletedTask);
    }

    private async Task DisposeControllerAsync()
    {
        await _actions.WaitAsync();
        try { await _controller.DisposeAsync(); }
        catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException)
        {
            Log?.Invoke(this, error.Message);
        }
        finally { _actions.Release(); _lifetime.Dispose(); }
    }
}
