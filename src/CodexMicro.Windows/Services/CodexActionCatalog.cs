namespace CodexMicro.Desktop.Services;

internal sealed record CodexActionDefinition(string Id, string Label, string IconId, string? LabelZh = null)
{
    public bool SoftwareSupported => CodexActionCatalog.SoftwareRoute(Id) is not null;
}

internal static partial class CodexActionCatalog
{
    internal static IEnumerable<CodexActionDefinition> All =>
        Official.Concat([
            new("turn.cancel", "Stop", "REJ"),
            // The composer menu exposes Sketch separately from the keyboard command registry.
            new("composer.sketch", "Sketch", "SKETCH"),
        ]);

    // Matches SoftwareMicroTransport's dispatch routes. Availability still depends
    // on the selected chat, current approval/turn, and the native UI adapter.
    internal static string? SoftwareRoute(string id) => id switch
    {
        "newTask" or "forkThread" or "toggleReviewTab" or
        "approval.approve" or "approval.decline" or
        "turn.cancel" or
        "composer.toggleFastMode" or "composer.togglePlanMode" or
        "composer.increaseReasoningEffort" or "composer.decreaseReasoningEffort" => "ipc",
        "composer.submit" or "composer.sketch" or "toggleSidebar" or "navigateBack" or "navigateForward" => "native-ui",
        _ => null,
    };

    internal static string? SoftwareUnavailableReason(string id, bool hasThread, bool hasDraft = false, bool hasComposer = false) =>
        id == "unassigned" ? "action.unassigned" :
        SoftwareRoute(id) is not { } route ? "action.unsupported" :
        (hasDraft || hasComposer) && IsComposerSetting(id) ? null :
        route == "ipc" && id != "newTask" && !hasThread ? "action.thread-required" : null;

    internal static bool IsComposerSetting(string id) => id is
        "composer.toggleFastMode" or "composer.togglePlanMode" or
        "composer.increaseReasoningEffort" or "composer.decreaseReasoningEffort";
}
