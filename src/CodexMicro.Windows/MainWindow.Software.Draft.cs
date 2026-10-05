using CodexMicro.Desktop.Services;
using CodexMicro.Protocol;

namespace CodexMicro.Desktop;

public partial class MicroSurfaceWindow
{
    private CodexDraftComposerModelSelector.DraftContext? _softwareDraft;

    private CodexModelToggleService.ForegroundDraftPresentationContext? CaptureDraftPresentationContext() =>
        !_softwareNavigationPending && CurrentCodexAgentThreadId() is null && _softwareDraft is { } draft &&
            CodexWindowActivator.IsForegroundWindow(draft.Presentation.Window) ? draft.Presentation : null;

    private async Task ToggleSoftwareQuickModelAsync()
    {
        if (_quickModelSwitching || _reasoningAdjusting || _windowClosed || SoftwareTargetPending) return;
        _quickModelSwitching = true;
        using var action = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        _modelActionCancellation = action;
        UpdateQuotaPresentation();
        try
        {
            // Re-read at dispatch; a timer's previous chat must not receive a new draft's click.
            var navigation = _softwareNavigationVersion;
            await ReadSoftwareThreadSelectionAsync(action.Token, waitForRead: true);
            if (_windowClosed || SoftwareTargetPending) return;
            if (navigation != _softwareNavigationVersion) return;
            var selected = _modelToggleService.CurrentVisibleThreadId;
            if (selected is not null)
            {
                _quickModelSwitchingThreadId = selected;
                await RunActionAsync(() => _broker.TapKeyAsync("ENC_QUICK"), "model");
                return;
            }
            var draft = await _draftComposerModelSelector.CaptureDraftContextAsync(_softwareDraft, action.Token);
            if (draft is null)
            {
                SetLed(ActivityLed, "#FFD66E", "快捷模型切换未完成");
                return;
            }
            _softwareDraft = draft;
            var profile = _profileSettings.Current;
            await RunActionAsync(async () =>
            {
                var result = await _draftComposerModelSelector.ToggleAsync(draft.Presentation.Window,
                    profile.QuickModelA, profile.QuickModelAEffort, profile.QuickModelB, profile.QuickModelBEffort,
                    profile.AutoConfirmUltraFullAccess, CodexModelToggleService.ForegroundDraftOperationPrefix + Guid.NewGuid().ToString("N"),
                    () => !action.IsCancellationRequested && draft.IsCurrent(), action.Token);
                if (!result.Succeeded) return new(
                    result.Error == "draft-renderer-mutation-outcome-unknown" ? MicroSendDisposition.OutcomeUnknown : MicroSendDisposition.NotSent,
                    0, 0, 0, result.Detail ?? result.Error ?? "Draft model unconfirmed");
                if (!await Task.Run(draft.IsCurrent)) return new(MicroSendDisposition.OutcomeUnknown, 0, 0, 0, "Draft changed");
                _draftQuickModelContext = draft.Presentation;
                _draftQuickModelSelection = (result.Current, result.CurrentEffort);
                ApplyAuthoritativeQuickModelState(_modelToggleService.CurrentThreadState);
                return new(MicroSendDisposition.Accepted, 0, 0, 0, "Draft model confirmed");
            }, "model", "Codex");
        }
        catch (OperationCanceledException)
        {
            if (!_windowClosed) SetLed(ActivityLed, "#FFD66E", "快捷模型切换未完成");
        }
        finally
        {
            _modelActionCancellation = null;
            _quickModelSwitching = false;
            _quickModelSwitchingThreadId = null;
            if (!_windowClosed) RefreshCurrentCodexThreadPresentation();
        }
    }
}
