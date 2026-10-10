using CodexMicro.Desktop.Services;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using CodexMicro.Protocol;
using CodexMicro.Codex;
using System.Text.Json;
using AgentController.Adapters.Codex.Windows;

namespace CodexMicro.Desktop;

public partial class MicroSurfaceWindow
{
    private readonly CodexSelectedThreadReader _softwareSelectionReader = new();
    private readonly SemaphoreSlim _softwareSelectionGate = new(1);
    private readonly Func<Task<bool>> _activateSoftwareApplication;
    private readonly Func<CancellationToken, Task<CodexThreadSelection>> _readSoftwareSelection;
    private string? _softwareSelectionPageKey;
    private CodexThreadSelection _softwareNavigationObservation;
    private string? _softwareNavigationOriginPageKey;
    private long _softwareSelectionGeneration;
    private long _softwareNavigationVersion;
    private bool _softwareNavigationPending;
    private string? _softwareNavigationTarget;
    private readonly Dictionary<string, int> _softwareFastPending = new(StringComparer.Ordinal);
    private CodexComposerTarget? _softwareUnidentifiedComposer;
    private (string TargetKey, bool Enabled)? _softwareComposerFast;
    private long _softwareActivityVersion;
    private bool? _softwareConnected;
    private bool SoftwareTargetPending => _softwareNavigationPending;

    private void RestoreSoftwareActivityIdle(bool preserveHelp = false)
    {
        var previousHelp = _helpContent.GetValueOrDefault(ActivityLed);
        if (_softwareConnected == true)
            SetLed(ActivityLed, "#9EBDFF", "Idle", title: "Activity");
        else
            SetLed(ActivityLed, NeutralStatusLed, "Idle", title: "Activity");
        if (preserveHelp && previousHelp != default)
            SetHelp(ActivityLed, previousHelp.Title, previousHelp.Detail);
    }

    private async Task ClearSoftwareActivityAsync(long version, int delayMilliseconds = 650)
    {
        await Task.Delay(delayMilliseconds);
        if (!_windowClosed && version == _softwareActivityVersion)
            RestoreSoftwareActivityIdle(preserveHelp: true);
    }

    private void PresentSoftwareActionResult(string label, MicroSendResult result, string? transportLabel = null)
    {
        var detail = _localization.ActionStatus(result.Detail);
        PresentAdjustmentFeedback(label, result);
        switch (result.Disposition)
        {
            case MicroSendDisposition.Accepted when result.IsBoundary:
                SetLed(ActivityLed, "#FFD66E", detail ?? string.Empty);
                SetStatus(detail ?? string.Empty);
                break;
            case MicroSendDisposition.Accepted:
                SetLed(ActivityLed, "#74D9A0", $"{label} 已交付\n{detail}");
                SetStatus($"{label} 已通过 {transportLabel ?? _transportName} 交付。\n{detail}");
                break;
            case MicroSendDisposition.NotSent when result.Detail == "action.unassigned":
                RestoreSoftwareActivityIdle();
                break;
            case MicroSendDisposition.OutcomeUnknown:
                SetLed(ActivityLed, "#FFD66E", $"{label} 结果未知\n{detail}");
                SetStatus($"{label} 效果未知；为避免双执行不会自动重试。\n{detail}");
                break;
            default:
                var unavailable = result.Disposition == MicroSendDisposition.NotSent &&
                    (result.Detail is "action.thread-required" or "action.target-unconfirmed" or "action.unsupported" or "action.busy" or
                        "ui.target.unavailable" or "ui.target.changed" or "ui.menu.unrelated" or
                        "ui.submit.unavailable" or "ui.history.unavailable");
                SetLed(ActivityLed, unavailable ? "#FFD66E" : "#FF7994", $"{label} 未发送\n{detail}");
                SetStatus($"{label} 未发送。\n{detail}");
                break;
        }
    }

    private static Task RecordSoftwareActionAsync(string label, MicroSendResult result) => Task.Run(() =>
        // The shared diagnostic sink serializes and rotates its small local log synchronously.
        // Keep that existing disk I/O off the surface's Dispatcher.
        SoftwareControlDiagnostics.Write("micro-action " + JsonSerializer.Serialize(new
        {
            action = label,
            disposition = result.Disposition.ToString(),
            detail = result.Detail,
        })));

    private void ApplyCoreSurface()
    {
        ActionKey12.ContextMenu = null;
        SettingsMenuItem.Items.Clear();
        SettingsMenuItem.Click += OpenSoftwareSettingsMenuItem_Click;
        KnobSettingsMenuItem.Items.Clear();
        KnobSettingsMenuItem.Click += OpenSoftwareSettingsMenuItem_Click;
        ApplySoftwareConnectionState(_broker.IsReady);
    }

    private async Task ConnectSoftwareAsync()
    {
        if (_connecting || _windowClosed) return;
        _connecting = true;
        try
        {
            var info = await _broker.RecoverCodexLinkAsync();
            if (_windowClosed) return;
            _transportName = info.TransportName;
            ApplySoftwareConnectionState(true);
        }
        catch (Exception error) when (error is IOException or TimeoutException or OperationCanceledException or ObjectDisposedException)
        {
            if (_windowClosed) return;
            ApplySoftwareConnectionState(false);
            SetStatus(error.Message);
        }
        finally { _connecting = false; }
    }

    private void ApplySoftwareConnectionState(bool connected)
    {
        var connectionChanged = _softwareConnected != connected;
        _softwareConnected = connected;
        var synchronized = connected && !_softwareNavigationPending &&
            ((_modelToggleService.CurrentThreadState is { } state &&
              state.ThreadId == _modelToggleService.CurrentVisibleThreadId) ||
             (_draftQuickModelContext is { } draft && CaptureDraftPresentationContext() == draft &&
              _draftQuickModelSelection is not null));
        SetLed(RuntimeLed, synchronized ? "#9EBDFF" : "#FFD66E",
            synchronized ? "Synced" : "Waiting", title: "Chat");
        SetLed(DriverLed, connected ? "#9EBDFF" : "#FFD66E",
            connected ? "Connected" : "Disconnected", title: "Codex IPC");
        if (connectionChanged) RestoreSoftwareActivityIdle();
    }

    internal void SelectSoftwareThread(string? threadId)
    {
        if ((threadId is not null && !Guid.TryParse(threadId, out _))) return;
        // Keep navigation intent separate from the confirmed current page.
        _softwareDraft = null;
        _softwareUnidentifiedComposer = null;
        CancelReasoningInput();
        _softwareNavigationOriginPageKey = _softwareSelectionPageKey;
        _softwareNavigationObservation = default;
        _softwareSelectionPageKey = null;
        _softwareNavigationPending = true;
        _softwareNavigationTarget = threadId;
        ++_softwareSelectionGeneration;
        var version = ++_softwareNavigationVersion;
        _modelToggleService.ObserveSelectedThread(null);
        RefreshCurrentCodexThreadPresentation();
        _ = ConfirmSoftwareNavigationAsync(version);
    }

    private static string? ResolveSoftwareThreadId(string? visibleThreadId) => visibleThreadId;

    private void RefreshSoftwareThreadSelection() => _ = ReadSoftwareThreadSelectionAsync();

    private async Task ReadSoftwareThreadSelectionAsync(CancellationToken token = default, bool waitForRead = false)
    {
        if (_windowClosed) return;
        if (waitForRead) await _softwareSelectionGate.WaitAsync(token);
        else if (!await _softwareSelectionGate.WaitAsync(0, token)) return;
        var generation = _softwareSelectionGeneration;
        try
        {
            var selection = await _readSoftwareSelection(token);
            if (_windowClosed || generation != _softwareSelectionGeneration) return;
            _softwareNavigationObservation = selection;
            var threadId = selection.ThreadId;
            // A new-chat request can still show the previous chat for a moment.
            // It can also reach a real chat before we ever observe the empty draft.
            if (_softwareNavigationPending && _softwareNavigationTarget is null && threadId is not null &&
                (selection.PageKey is null || selection.PageKey == _softwareNavigationOriginPageKey)) return;
            // Ignore the old page while a Micro-initiated navigation is still settling.
            if (_softwareNavigationPending && _softwareNavigationTarget is not null &&
                threadId != _softwareNavigationTarget)
            {
                if (_softwareNavigationOriginPageKey is null || selection.PageKey is null ||
                    selection.PageKey == _softwareNavigationOriginPageKey) return;
                // A different page was opened in Codex before our navigation completed.
                _softwareNavigationPending = false;
            }
            // Losing the sidebar is not a deselection. A changed or unreadable page is.
            if (!_softwareNavigationPending && selection.CanRetainThreadId && threadId is null && selection.PageKey is not null &&
                selection.PageKey == _softwareSelectionPageKey)
                threadId = _modelToggleService.CurrentVisibleThreadId;
            var changed = _modelToggleService.CurrentVisibleThreadId != threadId ||
                _softwareSelectionPageKey != selection.PageKey;
            var draft = threadId is null
                ? await _draftComposerModelSelector.CaptureDraftContextAsync(_softwareDraft, token)
                : null;
            var composer = threadId is null && draft is null
                ? await CodexUiController.ReadComposerTargetAsync(token)
                : null;
            if (_windowClosed || generation != _softwareSelectionGeneration) return;
            if (changed || draft?.Presentation != _softwareDraft?.Presentation) CancelReasoningInput();
            changed |= draft != _softwareDraft;
            changed |= composer != _softwareUnidentifiedComposer;
            _softwareDraft = draft;
            _softwareUnidentifiedComposer = composer;
            _softwareSelectionPageKey = selection.PageKey;
            if (_softwareNavigationPending &&
                (_softwareNavigationTarget is null ? threadId is not null || draft is not null :
                    threadId == _softwareNavigationTarget))
            {
                changed = true;
                _softwareNavigationPending = false;
                _manualUnreadThreads.Clear(threadId);
                SetLed(ActivityLed, "#74D9A0", "Opened", title: "Activity");
            }
            if (_modelToggleService.CurrentVisibleThreadId != threadId)
            {
                _modelToggleService.ObserveSelectedThread(threadId);
            }
            if (changed)
            {
                ++_softwareSelectionGeneration;
                RefreshCurrentCodexThreadPresentation();
            }
#if DEBUG
            if (changed || waitForRead)
                CodexModelToggleDiagnostics.RecordStage("selection-applied", new
                {
                    observedThreadId = selection.ThreadId,
                    retainedThreadId = selection.ThreadId is null && threadId is not null,
                    threadId,
                    selection.CanRetainThreadId,
                    targetChanged = changed,
                    hasPageIdentity = selection.PageKey is not null,
                    generation = _softwareSelectionGeneration,
                    navigationPending = _softwareNavigationPending,
                    hasDraft = draft is not null,
                    hasUnidentifiedComposer = composer is not null,
                });
#endif
        }
        catch (OperationCanceledException) { }
        finally { _softwareSelectionGate.Release(); }
    }

    private async Task ConfirmSoftwareNavigationAsync(long version)
    {
        // Shell URI dispatch may navigate a background Electron window without raising it.
        // Raise the actual main window so its selection and accessibility state refresh.
        await _activateSoftwareApplication();
        if (_windowClosed || version != _softwareNavigationVersion) return;
        var started = System.Diagnostics.Stopwatch.GetTimestamp();
        while (!_windowClosed && version == _softwareNavigationVersion && _softwareNavigationPending)
        {
            await ReadSoftwareThreadSelectionAsync();
            if (!_softwareNavigationPending || version != _softwareNavigationVersion || _windowClosed) return;
            if (System.Diagnostics.Stopwatch.GetElapsedTime(started) > TimeSpan.FromSeconds(4))
            {
                _softwareNavigationPending = false;
                // Navigation may fail or the user may navigate again. Do not bind the
                // requested ID to a different, unidentified page just because time elapsed.
                var observed = _softwareNavigationObservation;
                _modelToggleService.ObserveSelectedThread(observed.ThreadId);
                _softwareSelectionPageKey = observed.PageKey;
                ++_softwareSelectionGeneration;
                SetLed(ActivityLed, "#FFD66E", "Navigation unconfirmed", title: "Activity");
                RefreshCurrentCodexThreadPresentation();
                return;
            }
            await Task.Delay(60);
        }
    }

    private async Task<bool> ValidateSoftwareTargetAsync(string? expectedThreadId, CancellationToken token)
    {
        if (_windowClosed || SoftwareTargetPending) return false;
        var generation = _softwareSelectionGeneration;
        if (expectedThreadId is null)
        {
            if (_softwareDraft is { } draft)
            {
                var current = await _draftComposerModelSelector.CaptureDraftContextAsync(draft, token);
                return !_windowClosed && !_softwareNavigationPending && generation == _softwareSelectionGeneration &&
                    current is not null && current.Presentation == draft.Presentation;
            }
            if (CaptureUnidentifiedComposerTarget() is not { } composer) return false;
            var observed = await CodexUiController.ReadComposerTargetAsync(token);
            return !_windowClosed && !_softwareNavigationPending && generation == _softwareSelectionGeneration &&
                observed == composer;
        }
        await ReadSoftwareThreadSelectionAsync(token, waitForRead: true);
        if (_windowClosed || SoftwareTargetPending || generation != _softwareSelectionGeneration) return false;
        return _modelToggleService.CurrentVisibleThreadId == expectedThreadId;
    }

    private MicroControlContext CaptureSoftwareContext()
    {
        var threads = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var slot = 0; slot < 6; slot++)
        {
            if (_latestAgentRoster?.GetSlot(slot)?.ThreadId is { } thread)
                threads[$"AG{slot:00}"] = thread;
        }
        return new MicroControlContext(
            CurrentCodexAgentThreadId(), threads,
            _layoutObserver.Current, _profileSettings.Current, _softwareSelectionGeneration,
            CaptureDraftPresentationContext() is not null ? _softwareDraft?.ModelPickerId : null,
            CaptureUnidentifiedComposerTarget(), _softwareNavigationPending);
    }

    private CodexComposerTarget? CaptureUnidentifiedComposerTarget() =>
        !_softwareNavigationPending && CurrentCodexAgentThreadId() is null &&
        _softwareUnidentifiedComposer is { } target && CodexWindowActivator.IsForegroundWindow(target.Window)
            ? target : null;

    private void ObserveComposerFastApplied(MicroControlContext context, bool enabled)
    {
        if (!Dispatcher.CheckAccess())
        {
            _ = Dispatcher.InvokeAsync(() => ObserveComposerFastApplied(context, enabled));
            return;
        }
        if (_windowClosed || context.TargetVersion != _softwareSelectionGeneration ||
            context.ComposerTarget != CaptureUnidentifiedComposerTarget() ||
            context.DraftModelPickerId != (CaptureDraftPresentationContext() is not null ? _softwareDraft?.ModelPickerId : null) ||
            SoftwareFastTargetKey() is not { } key) return;
        _softwareComposerFast = (key, enabled);
        RefreshSoftwareFeedback();
    }

    private string? SoftwareFastTargetKey() => CurrentCodexAgentThreadId() ??
        (CaptureDraftPresentationContext() is not null
            ? $"draft:{_softwareSelectionGeneration}:{_softwareDraft!.ModelPickerId}"
            : CaptureUnidentifiedComposerTarget() is { } target
                ? $"composer:{_softwareSelectionGeneration}:{target.Window}:{target.ComposerId}:{target.ModelPickerId}" : null);

    private async Task HandleSoftwareKeyAsync(string key, bool agentKey)
    {
#if DEBUG
        using var diagnosticOperation = new System.Diagnostics.Activity("keypad:" + key).Start();
        RecordSoftwareTarget("input-before-selection", key);
#endif
        // A single Agent tap must navigate; the old focus preference must not consume it.
        var action = agentKey ? null : _layoutObserver.Current.GetSlot(key).ResolvedAction;
        if (action == "composer.toggleFastMode")
            await ReadSoftwareThreadSelectionAsync(waitForRead: true);
#if DEBUG
        RecordSoftwareTarget("input-after-selection", action ?? key);
#endif
        if (action is not null &&
            _layoutObserver.Current.GetSlot(key).Action is not { Type: "skill" } &&
            SoftwareActionUnavailableReason(action) is not null)
        {
#if DEBUG
            CodexModelToggleDiagnostics.RecordStage("input-rejected", new { action, reason = SoftwareActionUnavailableReason(action) });
#endif
            RefreshSoftwareActionAvailability();
            return;
        }
        if (action == "composer.submit" && !CodexWindowActivator.IsForeground())
        {
            // The first press only restores focus; sending still requires an explicit foreground press.
            if (await _activateSoftwareApplication() && !_windowClosed)
            {
                SetLed(ActivityLed, "#9EBDFF", "Codex 已置前");
                await ReadSoftwareThreadSelectionAsync();
            }
            return;
        }
        var fast = action == "composer.toggleFastMode";
        var fastThread = fast ? SoftwareFastTargetKey() : null;
        if (fast)
        {
            if (SystemParameters.ClientAreaAnimation && !SystemParameters.HighContrast &&
                _actionKeys.TryGetValue(key, out var presentation))
            {
                var scale = new ScaleTransform(1, 1);
                presentation.Icon.RenderTransformOrigin = new Point(.5, .5);
                presentation.Icon.RenderTransform = scale;
                var press = new DoubleAnimation(1, .82, TimeSpan.FromMilliseconds(95))
                { AutoReverse = true, FillBehavior = FillBehavior.Stop };
                scale.BeginAnimation(ScaleTransform.ScaleXProperty, press);
                scale.BeginAnimation(ScaleTransform.ScaleYProperty, press);
            }
            if (fastThread is not null)
                _softwareFastPending[fastThread] = _softwareFastPending.GetValueOrDefault(fastThread) + 1;
            RefreshSoftwareFeedback();
        }
        try
        {
            await RunActionAsync(() => _broker.TapKeyAsync(key), key);
        }
        finally
        {
            if (fast)
            {
                if (fastThread is not null && --_softwareFastPending[fastThread] == 0)
                    _softwareFastPending.Remove(fastThread);
                RefreshSoftwareFeedback();
            }
        }
    }

#if DEBUG
    private void RecordSoftwareTarget(string stage, string action) => CodexModelToggleDiagnostics.RecordStage(stage, new
    {
        action,
        selectedThreadId = _modelToggleService.CurrentVisibleThreadId,
        navigationTarget = _softwareNavigationTarget,
        navigationPending = _softwareNavigationPending,
        generation = _softwareSelectionGeneration,
        hasPageIdentity = _softwareSelectionPageKey is not null,
        hasDraft = _softwareDraft is not null,
        hasUnidentifiedComposer = _softwareUnidentifiedComposer is not null,
    });
#endif

    private void RefreshSoftwareFeedback()
    {
        if (_windowClosed) return;
        ApplySoftwareConnectionState(_broker.IsReady);
        RefreshSoftwareActionAvailability();
        var current = _modelToggleService.CurrentVisibleThreadId;
        var state = _modelToggleService.CurrentThreadState;
        var fastActive = current is not null && state?.ThreadId == current && CodexServiceTier.IsFast(state.ServiceTier);
        var fastTarget = SoftwareFastTargetKey();
        if (current is null && fastTarget is not null && _softwareComposerFast is { } composerFast &&
            composerFast.TargetKey == fastTarget)
            fastActive = composerFast.Enabled;
        foreach (var (key, presentation) in _actionKeys)
        {
            var fast = _layoutObserver.Current.GetSlot(key).ResolvedAction == "composer.toggleFastMode";
            if (!fast && !presentation.Icon.IsFastActive) continue;
            var pending = fast && fastTarget is not null && _softwareFastPending.ContainsKey(fastTarget);
            presentation.Icon.IsFastActive = fast && fastActive;
            presentation.Icon.IconBrush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(
                pending ? "#C28B21" : presentation.Icon.IsFastActive ? "#14876D" : "#171717"));
        }
        for (var slot = 0; slot < _agentKeys.Length; slot++)
            _agentKeys[slot].Opacity = SoftwareThreadFeedbackPending(_latestAgentRoster?.GetSlot(slot)?.ThreadId) ? .65 : 1;
        foreach (var key in _monitorKeys)
            key.Opacity = key.Tag is MonitorTask task && SoftwareThreadFeedbackPending(task.Id) ? .65 : 1;
    }

    private bool SoftwareThreadFeedbackPending(string? threadId) => threadId is not null &&
        ((_softwareNavigationPending && _softwareNavigationTarget == threadId) ||
         (_manualUnreadThreads.IsUnread(threadId) && !_manualUnreadThreads.IsConfirmed(threadId)));
}
