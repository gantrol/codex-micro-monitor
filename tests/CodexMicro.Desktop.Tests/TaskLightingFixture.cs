using System.IO;
using System.Text.Json;
using CodexMicro.Desktop.Services;

namespace CodexMicro.Desktop.Tests;

// Only the external Codex data is synthetic. Status parsing and monitoring use
// the production implementation, including path validation and incremental reads.
internal sealed class TaskLightingFixture : IAsyncDisposable
{
    internal const string ThreadId = "01000000-0000-0000-0000-000000000001";
    internal const string TurnId = "fixture-turn";
    internal const string Title = "Interrupted task awaiting continuation";
    private static readonly string Parent = Path.Combine(Path.GetTempPath(), "micro-task-lighting-tests");

    internal string Root { get; } = Path.Combine(Parent, Guid.NewGuid().ToString("N"));
    internal string RolloutPath => Path.Combine(Root, "sessions", "rollout.jsonl");
    internal string ModelsPath => Path.Combine(Root, "models.json");
    internal DateTimeOffset StartedAt { get; private set; }

    private TaskLightingFixture() { }

    internal static async Task<TaskLightingFixture> CreateAsync(double ageHours = 8)
    {
        var fixture = new TaskLightingFixture { StartedAt = DateTimeOffset.UtcNow.AddHours(-ageHours) };
        try
        {
            await Task.Run(() => Directory.CreateDirectory(Path.GetDirectoryName(fixture.RolloutPath)!));
            await fixture.AppendAsync(new { type = "task_started", turn_id = TurnId }, fixture.StartedAt);
            return fixture;
        }
        catch
        {
            await fixture.DisposeAsync();
            throw;
        }
    }

    internal CodexTaskMonitorService CreateMonitor(bool unread = false) => new(
        codexRoot: Root,
        readThreads: token =>
        {
            token.ThrowIfCancellationRequested();
            return Task.FromResult<IReadOnlyList<CodexRecentThread>?>(
                [new(ThreadId, Title, null, StartedAt, RolloutPath)]);
        },
        readUnread: token =>
        {
            token.ThrowIfCancellationRequested();
            return Task.FromResult<CodexUnreadStateSnapshot?>(new(
                unread ? new HashSet<string> { ThreadId } : new HashSet<string>(), null));
        });

    internal Task AppendAsync(object payload, DateTimeOffset? timestamp = null) => File.AppendAllTextAsync(RolloutPath,
        JsonSerializer.Serialize(new { timestamp = timestamp ?? DateTimeOffset.UtcNow, type = "event_msg", payload }) + "\n");

    public async ValueTask DisposeAsync()
    {
        var parent = Path.GetFullPath(Parent) + Path.DirectorySeparatorChar;
        var target = Path.GetFullPath(Root);
        if (!target.StartsWith(parent, StringComparison.OrdinalIgnoreCase) ||
            Path.GetDirectoryName(target) != Path.GetFullPath(Parent))
            throw new InvalidOperationException("Fixture cleanup escaped its temporary parent");

        // Directory cleanup has no async API. Remove this fixture's single small
        // directory on a worker, never on the WPF Dispatcher.
        await Task.Run(() =>
        {
            if (Directory.Exists(target)) Directory.Delete(target, recursive: true);
        });
    }
}
