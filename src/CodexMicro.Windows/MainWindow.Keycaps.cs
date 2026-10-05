using System.Windows.Automation;
using System.Windows.Controls;
using CodexMicro.Desktop.Services;

namespace CodexMicro.Desktop;

public partial class MicroSurfaceWindow
{
    private void SetActionKeyHelp(Button button, CodexMicroSlotBinding binding)
    {
        var command = CodexActionCatalog.All.FirstOrDefault(action => action.Id == binding.ResolvedAction);
        var skill = binding.Action is { Type: "skill" };
        var label = skill ? binding.Action!.Id
            : command is not null ? _localization.ActionLabel(command)
            : binding.Action is not null || binding.CommandId is not null ? binding.ResolvedAction
            : CodexKeycapCatalog.Get(binding.KeycapId).Label;
        var reason = skill ? null : SoftwareActionUnavailableReason(binding.ResolvedAction);
        var status = _localization.ActionStatus(reason) ?? string.Empty;
        button.IsEnabled = reason is null;
        ToolTipService.SetShowOnDisabled(button, true);
        ContextMenuService.SetShowOnDisabled(button, true);
        if (!_helpContent.TryGetValue(button, out var help) || help != (label, status))
            SetHelp(button, label, status);
        AutomationProperties.SetItemStatus(button, status);
    }

    private string? SoftwareActionUnavailableReason(string action)
    {
        if (!_broker.UsesSoftwareControl) return null;
        return CodexActionCatalog.SoftwareUnavailableReason(action,
            !_softwareNavigationPending && CurrentCodexAgentThreadId() is not null,
            CaptureDraftPresentationContext() is not null, CaptureUnidentifiedComposerTarget() is not null);
    }

    private string? SoftwareJoystickUnavailableReason(string direction)
    {
        var action = SoftwareJoystickAction(direction);
        return CodexActionCatalog.SoftwareUnavailableReason(action,
            !_softwareNavigationPending && CurrentCodexAgentThreadId() is not null,
            CaptureDraftPresentationContext() is not null, CaptureUnidentifiedComposerTarget() is not null);
    }

    private string SoftwareJoystickAction(string direction) =>
        _layoutObserver.Current.AnalogActions.GetValueOrDefault(direction) ?? (direction switch
        {
            "up" => "composer.togglePlanMode", "down" => "toggleSidebar",
            "left" => "navigateBack", "right" => "navigateForward", _ => "unassigned",
        });

    private void RefreshSoftwareActionAvailability()
    {
        foreach (var (key, presentation) in _actionKeys)
            SetActionKeyHelp(presentation.Button, _layoutObserver.Current.GetSlot(key));
        foreach (var (direction, button) in _joystickButtons)
        {
            var reason = SoftwareJoystickUnavailableReason(direction);
            var action = SoftwareJoystickAction(direction);
            var command = CodexActionCatalog.All.FirstOrDefault(item => item.Id == action);
            var label = command is null ? action : _localization.ActionLabel(command);
            var status = _localization.ActionStatus(reason) ?? string.Empty;
            button.IsEnabled = reason is null;
            ToolTipService.SetShowOnDisabled(button, true);
            if (!_helpContent.TryGetValue(button, out var help) || help != (label, status))
                SetHelp(button, label, status);
            AutomationProperties.SetItemStatus(button, status);
        }
    }
}
