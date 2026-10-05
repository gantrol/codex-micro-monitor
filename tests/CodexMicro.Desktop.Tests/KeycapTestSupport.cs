using System.Windows.Threading;

namespace CodexMicro.Desktop.Tests;

// Expected product contracts are explicit; no production catalog builds its own oracle.
public static class KeycapCases
{
    public static readonly string[] Slots =
        ["ACT06", "ACT07", "ACT08", "ACT09", "ACT10", "ACT11", "ACT10_ACT11", "ACT12"];

    public static readonly string[] Commands =
    [
        "newTask", "forkThread", "composer.toggleFastMode", "composer.togglePlanMode",
        "toggleReviewTab", "approval.approve", "approval.decline",
        "composer.increaseReasoningEffort", "composer.decreaseReasoningEffort", "turn.cancel",
        "composer.submit", "composer.sketch", "toggleSidebar", "navigateBack", "navigateForward",
    ];

    public static IEnumerable<object[]> SlotCases() => Slots.Select(slot => new object[] { slot });
    public static IEnumerable<object[]> CommandCases() => Commands.Select(command => new object[] { command });
    public static IEnumerable<object[]> CatalogCases()
    {
        var expected = """
            FAST|composer.toggleFastMode
            APPR|approval.approve
            REJ|approval.decline
            SPLIT|forkThread
            MIC|dictation.pushToTalk|double
            MIC1|dictation.pushToTalk
            CODEX|composer.submit
            BUG|feedback
            OAI|developers.openai.com
            TERM|toggleTerminal
            DWN|copyConversationMarkdown
            DEL|archiveThread
            NEW|newTask
            NAV|openBrowserTab
            MAGIC|toggleThreadPin
            DIFF|toggleReviewTab
            PLAY|environmentAction1
            GIT|git.commit
            BRCH|git.createDraftPullRequest
            BRANCH|git.createBranch
            MRG|git.mergePullRequest
            PR|git.createPullRequest
            PAINT|composer.addPhotos
            SKETCH|composer.sketch
            LAB|settings
            PARTY|openSideChat
            TIME|manageTasks
            MIND+|composer.increaseReasoningEffort
            MIND-|composer.decreaseReasoningEffort
            EMPT1|unassigned
            EMPT2|unassigned
            EMPT3|unassigned
            EMPT4|unassigned
            SETUP|settings
            FOLD|openFolder
            UPL|composer.addFiles
            APPS|openSkills
            YOLO|custom
            YEET|custom
            EMPT5|unassigned|double
            """;
        foreach (var line in expected.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = line.Trim().Split('|');
            yield return [parts[0], parts[1], parts.Length == 3 ? parts[2] : "single"];
        }
    }
}

internal sealed class KeycapTestFiles : IDisposable
{
    internal string Root { get; } = Path.Combine(Path.GetTempPath(), "micro-keycap-tests", Guid.NewGuid().ToString("N"));
    internal string Config => Path.Combine(Root, "config.toml");
    internal string Profile => Path.Combine(Root, "profile.json");
    internal string Models => Path.Combine(Root, "models.json");
    internal KeycapTestFiles() => Directory.CreateDirectory(Root);

    public void Dispose()
    {
        var parent = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "micro-keycap-tests")) + Path.DirectorySeparatorChar;
        var target = Path.GetFullPath(Root);
        if (!target.StartsWith(parent, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Fixture cleanup escaped its temporary parent");
        Directory.Delete(target, recursive: true);
    }
}

internal static class KeycapUiThread
{
    internal static Task Run(Func<Task> action)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            dispatcher.BeginInvoke(new Action(async () =>
            {
                try { await action(); completion.TrySetResult(); }
                catch (Exception error) { completion.TrySetException(error); }
                finally { dispatcher.BeginInvokeShutdown(DispatcherPriority.Send); }
            }));
            Dispatcher.Run();
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return completion.Task.WaitAsync(TimeSpan.FromSeconds(15));
    }
}
