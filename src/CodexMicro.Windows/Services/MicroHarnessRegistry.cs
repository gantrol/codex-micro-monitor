namespace CodexMicro.Desktop.Services;

internal sealed record MicroHarnessConnectionSettings(
    string? PipeName,
    string? Executable,
    string? Arguments,
    string? WorkingDirectory,
    bool AutoStart,
    int ReadyTimeoutMilliseconds = 60_000,
    string? ControlUri = null);

internal sealed record MicroHarnessDefinition(
    string Id,
    string DisplayName,
    string Description,
    string? ProjectPath,
    bool IsAvailable,
    MicroHarnessConnectionSettings Connection)
{
    internal string? PipeName => Connection.PipeName;
    internal string? ControlUri => Connection.ControlUri;

    public override string ToString() => DisplayName;
}

internal enum MicroHarnessDispatchStage
{
    Connecting,
    Starting,
    WaitingForAdapter,
    Opening,
    Foreground,
    Background,
    Completed,
    Failed,
}

internal sealed record MicroHarnessDispatchProgress(
    MicroHarnessDispatchStage Stage,
    string Message,
    int? Step = null,
    int? TotalSteps = null);

internal sealed record MicroHarnessDispatchResult(
    bool Success,
    string Message,
    MicroHarnessDispatchStage Stage,
    int? WindowProcessId = null,
    int? Step = null,
    int? TotalSteps = null);

internal sealed record MicroHarnessTimeoutDiagnostic(
    string HarnessId,
    DateTimeOffset TimedOutAt,
    int ConfiguredTimeoutMilliseconds,
    int ElapsedMilliseconds,
    int ProbeAttempts,
    string LastProbeMessage,
    int? LauncherProcessId,
    bool? LauncherWasRunning,
    int? LauncherExitCode);

internal sealed class CallbackProgress<T>(Action<T> callback) : IProgress<T>
{
    public void Report(T value) => callback(value);
}

internal static class MicroHarnessActionIds
{
    internal const string None = "none";
    internal const string NewSession = "session/new";
    internal const string ForkSession = "session/fork";
    internal const string ArchiveSession = "session/archive";
    internal const string CancelTurn = "turn/cancel";
    internal const string ToggleConversationView =
        "view/toggle-chat-trajectory";
    internal const string ApproveInteraction = "interaction/approve";
    internal const string RejectInteraction = "interaction/reject";
    internal const string LoadOlderHistory = "history/load-older";
    internal const string ToggleSidebar = "layout/toggle-sidebar";
    internal const string OpenDetails = "layout/open-details";
    internal const string CloseDetails = "layout/close-details";
    internal const string PreviousSession = "session/previous";
    internal const string NextSession = "session/next";
    internal const string OpenSelectedSession = "session/open-selected";
    internal const string ActivateSurface = "surface/activate";
    internal const string VoiceDictation = "voice/dictation";
    internal const string ComposerSelectPrevious = "composer/select-previous";
    internal const string ComposerSelectNext = "composer/select-next";
    internal const string ComposerActivateSelection =
        "composer/activate-selection";
    internal const string ComposerBack = "composer/back";
    internal const string ComposerSubmit = "composer/submit";
    internal const string ReasoningDecrease = "reasoning/decrease";
    internal const string ReasoningIncrease = "reasoning/increase";
    internal const string ToggleQuickModel = "model/toggle-quick";
    internal const string OpenGoal = "goal/open";

    internal static readonly IReadOnlyList<string> Configurable =
    [
        None,
        NewSession,
        ToggleConversationView,
        ApproveInteraction,
        CancelTurn,
        ForkSession,
        RejectInteraction,
        ArchiveSession,
        LoadOlderHistory,
        ToggleSidebar,
        OpenDetails,
        CloseDetails,
        PreviousSession,
        NextSession,
        OpenSelectedSession,
        ActivateSurface,
        VoiceDictation,
        OpenGoal,
    ];

    internal static bool IsNative(string actionId) =>
        actionId is NewSession or
            ToggleConversationView or
            ForkSession or
            ArchiveSession or
            CancelTurn or
            ApproveInteraction or
            RejectInteraction or
            LoadOlderHistory or
            ToggleSidebar or
            OpenDetails or
            CloseDetails or
            ComposerSelectPrevious or
            ComposerSelectNext or
            ComposerActivateSelection or
            ComposerBack or
            ComposerSubmit or
            ReasoningDecrease or
            ReasoningIncrease or
            ToggleQuickModel or
            OpenGoal;

    internal static bool IsVoice(string actionId) =>
        actionId == VoiceDictation;
}

internal static class MicroHarnessKnobModes
{
    internal const string ComposerNavigation = "composer-navigation";
    internal const string ReasoningOnly = "reasoning";
    // Read-only migration alias from the first external-Harness prototype.
    internal const string QuickActions = "quick-actions";
    internal const string RecentSessions = "recent-sessions";

    internal static readonly IReadOnlyList<string> Configurable =
    [
        ComposerNavigation,
        ReasoningOnly,
        RecentSessions,
    ];
}

internal static class MicroHarnessControlIds
{
    internal const string Action06 = "ACT06";
    internal const string Action07 = "ACT07";
    internal const string Action08 = "ACT08";
    internal const string Action09 = "ACT09";
    internal const string VoiceWide = "ACT10_ACT11";
    internal const string VoiceLeft = "ACT10";
    internal const string VoiceRight = "ACT11";
    internal const string JoystickUp = "JOY_UP";
    internal const string JoystickDown = "JOY_DOWN";
    internal const string JoystickLeft = "JOY_LEFT";
    internal const string JoystickRight = "JOY_RIGHT";

    internal static readonly IReadOnlyList<string> All =
    [
        Action06,
        Action07,
        Action08,
        Action09,
        VoiceWide,
        VoiceLeft,
        VoiceRight,
        JoystickUp,
        JoystickDown,
        JoystickLeft,
        JoystickRight,
    ];

    internal static bool IsVoice(string controlId) =>
        controlId is VoiceWide or VoiceLeft or VoiceRight;
}

internal sealed record MicroHarnessKeyMap(
    IReadOnlyDictionary<string, string> Bindings)
{
    internal string Resolve(string controlId) =>
        Bindings.TryGetValue(controlId, out var actionId)
            ? actionId
            : MicroHarnessActionIds.None;
}

internal sealed record MicroHarnessCapabilities(
    bool SessionList,
    bool SessionActivation,
    bool KnobSettings,
    bool VoiceInput,
    IReadOnlySet<string> Actions)
{
    internal bool Supports(string actionId) => Actions.Contains(actionId);
}

internal enum MicroHarnessSessionStatus
{
    Idle,
    Running,
    Completed,
    WaitingForInput,
    Error,
}

internal sealed record MicroHarnessSession(
    string Id,
    string DisplayTitle,
    MicroHarnessSessionStatus Status,
    long UpdatedAt)
{
    internal bool Running => Status == MicroHarnessSessionStatus.Running;
}

internal sealed record MicroHarnessComponentSnapshot(
    string Adapter,
    string Browser,
    string? CurrentModel = null);

internal sealed record MicroHarnessVoiceRequest(
    string RequestId,
    string? SessionId);

internal sealed record MicroHarnessStateSnapshot(
    string HarnessId,
    IReadOnlyList<MicroHarnessSession> Sessions,
    string? CurrentSessionId,
    MicroHarnessCapabilities Capabilities,
    int NavigationDepth,
    MicroHarnessComponentSnapshot? Components,
    DateTimeOffset ReadAt);

// Preserves profile/editor contracts while restricting the product to Codex.
internal sealed class MicroHarnessRegistry
{
    private static readonly MicroHarnessDefinition Codex = new("codex", "Codex", "Codex software control", null, true, new(null, null, null, null, false, 0));
    internal MicroHarnessRegistry(bool codexOnly = true) { }
    internal event EventHandler? Changed { add { } remove { } }
    internal IReadOnlyList<MicroHarnessDefinition> Definitions => [Codex];
    internal bool LastSaveSucceeded => true;
    internal MicroHarnessDefinition Resolve(string? id) => Codex;
    internal string ResolveKnobMode(string harnessId) => MicroHarnessKnobModes.ComposerNavigation;
    internal MicroHarnessKeyMap ResolveKeyMap(string harnessId) => new(new Dictionary<string, string>());
    internal bool UpdateKeyMapping(string harnessId, string controlId, string actionId) => false;
    internal Task<MicroHarnessDispatchResult> ActivateSessionAsync(string harnessId, string sessionId, CancellationToken cancellationToken = default) =>
        Task.FromResult(new MicroHarnessDispatchResult(false, "External adapters are not included.", MicroHarnessDispatchStage.Failed));
}
