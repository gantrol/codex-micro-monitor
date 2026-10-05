using System.Windows;
using System.Windows.Automation;
using WpfControl = System.Windows.Controls.Control;
using System.Windows.Media.Animation;
using CodexMicro.Desktop.Controls;
using CodexMicro.Protocol;

namespace CodexMicro.Desktop;

public partial class MicroSurfaceWindow
{
    private readonly Dictionary<WpfControl, (long Version, string Detail, KeycapIcon? Icon)> _adjustmentFeedback = new();
    private long _adjustmentFeedbackVersion;

    private WpfControl? AdjustmentControl(string label) =>
        _actionKeys.TryGetValue(label, out var key) ? key.Button :
        label is "reasoning" ? SettingsKey :
        label is "encoder" ? DialButton :
        label.StartsWith("analog ", StringComparison.Ordinal) &&
            _joystickButtons.TryGetValue(label[7..].ToLowerInvariant(), out var button) ? button : null;

    private string? AdjustmentStatus(WpfControl control) => _adjustmentFeedback.TryGetValue(control, out var feedback)
        ? _localization.ActionStatus(feedback.Detail) : null;

    private string? ReasoningKeyBoundaryResource(string label, string detail) =>
        !_actionKeys.ContainsKey(label) ? null : detail switch
        {
            "ui.reasoning.maximum" => "AdjustmentMaximumBrush",
            "ui.reasoning.minimum" => "AdjustmentMinimumBrush",
            _ => null,
        };

    private void PresentAdjustmentFeedback(string label, MicroSendResult result)
    {
        if (_windowClosed || AdjustmentControl(label) is not { } control) return;
        ClearAdjustmentFeedback(control);
        if (!result.IsBoundary) return;
        var version = ++_adjustmentFeedbackVersion;
        var resource = ReasoningKeyBoundaryResource(label, result.Detail);
        var icon = resource is null ? null : _actionKeys[label].Icon;
        _adjustmentFeedback[control] = (version, result.Detail, icon);
        var color = SystemParameters.HighContrast ? SystemColors.HighlightBrush :
            FindResource(resource ??
                (control == SettingsKey ? "AdjustmentBoundaryKnobBrush" : "AdjustmentBoundaryBrush"));
        // A steady, brief color change also works with reduced motion. Repeated input
        // restarts the duration; the animation restores the current style automatically.
        var feedback = new ObjectAnimationUsingKeyFrames { Duration = TimeSpan.FromMilliseconds(900), FillBehavior = FillBehavior.Stop };
        feedback.KeyFrames.Add(new DiscreteObjectKeyFrame(color, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        if (icon is not null)
            icon.BeginAnimation(KeycapIcon.FeedbackBrushProperty, feedback);
        else
            control.BeginAnimation(WpfControl.BackgroundProperty, feedback);
        AutomationProperties.SetItemStatus(control, AdjustmentStatus(control));
        _ = ClearAdjustmentFeedbackAsync(control, version);
    }

    private async Task ClearAdjustmentFeedbackAsync(WpfControl control, long version)
    {
        await Task.Delay(900);
        if (_windowClosed || !_adjustmentFeedback.TryGetValue(control, out var feedback) || feedback.Version != version) return;
        ClearAdjustmentFeedback(control);
        RefreshSoftwareActionAvailability();
    }

    private void ClearAdjustmentFeedback(WpfControl control)
    {
        if (!_adjustmentFeedback.Remove(control, out var feedback)) return;
        if (feedback.Icon is { } icon)
            icon.BeginAnimation(KeycapIcon.FeedbackBrushProperty, null);
        else
            control.BeginAnimation(WpfControl.BackgroundProperty, null);
        AutomationProperties.SetItemStatus(control, string.Empty);
    }
}
