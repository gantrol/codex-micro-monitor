using System.IO;
using System.Windows.Media;
using CodexMicro.Core.Models;
using CodexMicro.Core.Services;
using CodexMicro.Desktop.Services;
using Xunit;

namespace CodexMicro.Desktop.Tests;

[Trait("Scope", "TaskLighting"), Trait("Layer", "Component")]
public sealed class TaskLightingComponentTests
{
    [Theory]
    [InlineData(0)]
    [InlineData(8)]
    public async Task UnclosedRolloutWithoutRuntimeConfirmationIsUnknown(double ageHours)
    {
        await using var fixture = await TaskLightingFixture.CreateAsync(ageHours);
        var monitor = fixture.CreateMonitor();

        var snapshot = Assert.IsType<CodexTaskMonitorSnapshot>(await monitor.ReadAsync(CancellationToken.None));

        var task = Assert.Single(snapshot.Tasks);
        Assert.Equal(TaskLightingFixture.ThreadId, task.Id);
        Assert.Equal(TaskLightingFixture.Title, task.Title);
        Assert.Equal(task.Id, Assert.Single(snapshot.AgentRoster.Entries).ThreadId);
        Assert.Equal(ThreadStatus.Unknown, task.Status);
        Assert.False(task.HasPendingQuestion);
    }

    [Fact]
    public async Task PollingAndRestartDoNotPromoteAnUnconfirmedTurnToRunning()
    {
        await using var fixture = await TaskLightingFixture.CreateAsync();
        var persisted = await File.ReadAllTextAsync(fixture.RolloutPath);
        var observed = new List<ThreadStatus>();
        for (var launch = 0; launch < 2; launch++)
        {
            var monitor = fixture.CreateMonitor();
            for (var poll = 0; poll < 3; poll++)
            {
                var full = Assert.IsType<CodexTaskMonitorSnapshot>(await monitor.ReadAsync(CancellationToken.None));
                observed.Add(Assert.Single(full.Tasks).Status);
                var questions = Assert.IsType<CodexTaskMonitorSnapshot>(
                    await monitor.ReadPendingQuestionsAsync(CancellationToken.None));
                observed.Add(Assert.Single(questions.Tasks).Status);
            }
        }

        Assert.Equal(persisted, await File.ReadAllTextAsync(fixture.RolloutPath));
        Assert.All(observed, status => Assert.Equal(ThreadStatus.Unknown, status));
    }

    [Theory]
    [InlineData("task_complete", null, ThreadStatus.Idle)]
    [InlineData("turn_aborted", null, ThreadStatus.Idle)]
    [InlineData("task_complete", "server_overloaded", ThreadStatus.Error)]
    [InlineData("turn_aborted", "server_overloaded", ThreadStatus.Error)]
    public async Task ExplicitTerminalEventStillResolvesWithoutRuntimeConfirmation(
        string eventType, string? errorCode, ThreadStatus expected)
    {
        await using var fixture = await TaskLightingFixture.CreateAsync();
        var monitor = fixture.CreateMonitor();
        Assert.NotNull(await monitor.ReadAsync(CancellationToken.None));
        await fixture.AppendAsync(new
        {
            type = eventType,
            turn_id = TaskLightingFixture.TurnId,
            error = errorCode is null ? null : new { codex_error_info = errorCode },
        });

        var snapshot = Assert.IsType<CodexTaskMonitorSnapshot>(await monitor.ReadAsync(CancellationToken.None));

        var task = Assert.Single(snapshot.Tasks);
        Assert.Equal(expected, task.Status);
        Assert.Equal(errorCode, task.ErrorCode);
        Assert.False(task.HasPendingQuestion);
    }

    [Fact]
    public async Task RolloutReaderPreservesOpenTurnEvidenceForTheMonitorToReconcile()
    {
        await using var fixture = await TaskLightingFixture.CreateAsync();
        var reader = new CodexRolloutStatusReader();

        var open = await Task.Run(() => reader.ReadSnapshot(fixture.RolloutPath));
        Assert.Equal(ThreadStatus.Thinking, open.Status);
        await fixture.AppendAsync(new { type = "turn_aborted", turn_id = TaskLightingFixture.TurnId });
        var stopped = await Task.Run(() => reader.ReadSnapshot(fixture.RolloutPath));
        Assert.Equal(ThreadStatus.Idle, stopped.Status);
    }

    [Theory]
    [InlineData(null, false)]
    [InlineData(null, true)]
    [InlineData((int)MicroHarnessSessionStatus.Idle, false)]
    [InlineData((int)MicroHarnessSessionStatus.Idle, true)]
    public void UnknownOrIdleCodexSessionUsesNeutralLighting(
        int? statusValue, bool selected)
    {
        var status = statusValue is { } value ? (MicroHarnessSessionStatus?)value : null;
        var appearance = AgentLightingAppearance.FromCodexSession(status, selected).ForDisplay();

        Assert.Equal(selected, appearance.IsCurrentSession);
        Assert.Equal(selected ? 1 : 0, appearance.DisplayOpacity);
        if (selected) Assert.Equal(Colors.White, appearance.Color);
        Assert.NotEqual(Color.FromRgb(0x30, 0x4F, 0xFE), appearance.Color);
    }

    [Fact]
    public async Task IdleRuntimeSuppressesStaleQuestionsOnBothPollsAndActiveRuntimeOverridesOldErrors()
    {
        await using var fixture = await TaskLightingFixture.CreateAsync();
        await fixture.AppendAsync(new
        {
            type = "item_completed", turn_id = TaskLightingFixture.TurnId,
            item = new { type = "AgentMessage", id = "question", delivery = "async", questions = new[] { new { title = "Choose" } } },
        });
        var monitor = fixture.CreateMonitor();
        monitor.ObserveActivity(new(TaskLightingFixture.ThreadId, 1, new(ThreadStatus.Thinking)));
        Assert.True(Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks).HasPendingQuestion);
        Assert.Single(monitor.GetPendingQuestions());
        monitor.ObserveActivity(new(TaskLightingFixture.ThreadId, 2, new(ThreadStatus.Idle)));
        for (var poll = 0; poll < 2; poll++)
        {
            var task = Assert.Single((await monitor.ReadPendingQuestionsAsync(CancellationToken.None))!.Tasks);
            Assert.Equal(ThreadStatus.Idle, task.Status);
            Assert.False(task.HasPendingQuestion);
            Assert.Empty(monitor.GetPendingQuestions());
            Assert.Equal(ThreadStatus.Idle, Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks).Status);
        }
        await fixture.AppendAsync(new
        {
            type = "task_complete", turn_id = TaskLightingFixture.TurnId, error = new { codex_error_info = "server_overloaded" },
        });
        Assert.Equal(ThreadStatus.Error, Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks).Status);
        var resumed = Assert.Single(monitor.ObserveActivity(new(TaskLightingFixture.ThreadId, 3, new(ThreadStatus.Thinking)))!.Tasks);
        Assert.Equal(ThreadStatus.Thinking, resumed.Status);
        Assert.Null(resumed.ErrorCode);
        Assert.False(resumed.HasPendingQuestion);
    }

    [Fact]
    public async Task UnreadDoesNotReplaceConfirmedRunningOrWaitingButStillLightsIdleTasks()
    {
        await using var fixture = await TaskLightingFixture.CreateAsync();
        var monitor = fixture.CreateMonitor(unread: true);
        long sequence = 0;
        foreach (var status in new[] { ThreadStatus.Thinking, ThreadStatus.RequiresInput, ThreadStatus.Error, ThreadStatus.Idle })
        {
            monitor.ObserveActivity(new(TaskLightingFixture.ThreadId, ++sequence, new(status)));
            Assert.Equal(status == ThreadStatus.Idle ? ThreadStatus.CompleteUnread : status,
                Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks).Status);
        }
    }

    [Fact]
    public void ConfirmedRunningCodexSessionStillUsesBlue()
    {
        var appearance = AgentLightingAppearance.FromCodexSession(
            MicroHarnessSessionStatus.Running, isCurrentSession: true).ForDisplay();

        Assert.Equal(Color.FromRgb(0x30, 0x4F, 0xFE), appearance.Color);
        Assert.Equal(1, appearance.DisplayOpacity);
    }

    [Fact]
    public async Task MetadataUnavailableDuringRestartKeepsTaskIdentityWithoutInventingAnError()
    {
        await using var fixture = await TaskLightingFixture.CreateAsync();
        var available = true;
        var monitor = new CodexTaskMonitorService(fixture.Root,
            readThreads: _ => Task.FromResult<IReadOnlyList<CodexRecentThread>?>(available
                ? [new(TaskLightingFixture.ThreadId, TaskLightingFixture.Title, null, fixture.StartedAt, fixture.RolloutPath)] : null),
            readUnread: _ => Task.FromResult<CodexUnreadStateSnapshot?>(null));
        // Cold start can subscribe and classify tasks even while unread lookup
        // is unavailable; it must not discard the whole roster.
        var initial = Assert.IsType<CodexTaskMonitorSnapshot>(await monitor.ReadAsync(CancellationToken.None));
        Assert.Equal(TaskLightingFixture.ThreadId, Assert.Single(initial.Tasks).Id);
        monitor.ObserveActivity(new(TaskLightingFixture.ThreadId, 1, new(ThreadStatus.Thinking)));
        monitor.ObserveActivity(new(TaskLightingFixture.ThreadId, 2, CodexThreadActivity.Unknown));
        available = false;
        var unobserved = Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks);
        Assert.Equal(TaskLightingFixture.ThreadId, unobserved.Id);
        Assert.Equal(TaskLightingFixture.Title, unobserved.Title);
        Assert.Equal(ThreadStatus.Unknown, unobserved.Status);
        Assert.Null(unobserved.ErrorCode);
        Assert.Null(monitor.RecentThreads);
    }

    [Fact]
    public async Task ExplicitFailureSurvivesMonitorRestartAndClearsWhenWorkResumes()
    {
        await using var fixture = await TaskLightingFixture.CreateAsync();
        await fixture.AppendAsync(new
        {
            type = "task_complete", turn_id = TaskLightingFixture.TurnId,
            error = new { codex_error_info = "server_overloaded" },
        });
        for (var launch = 0; launch < 2; launch++)
        {
            var monitor = fixture.CreateMonitor();
            await monitor.ReadAsync(CancellationToken.None);
            monitor.ObserveActivity(new(TaskLightingFixture.ThreadId, 1, new(ThreadStatus.Idle)));
            var failed = Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks);
            Assert.Equal(ThreadStatus.Error, failed.Status);
            Assert.Equal("server_overloaded", failed.ErrorCode);
            var resumed = Assert.Single(monitor.ObserveActivity(
                new(TaskLightingFixture.ThreadId, 2, new(ThreadStatus.Thinking)))!.Tasks);
            Assert.Equal(ThreadStatus.Thinking, resumed.Status);
            Assert.Null(resumed.ErrorCode);
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ExplicitTaskErrorsUseExistingRedErrorLightAndLocalizedStatus(bool selected)
    {
        var appearance = AgentLightingAppearance.FromCodexSession(
            MicroHarnessSessionStatus.Error, selected, "execution_error").ForDisplay();
        Assert.Equal(Color.FromRgb(0xFF, 0x00, 0x33), appearance.Color);
        Assert.Equal(selected ? 1 : 0.94, appearance.DisplayOpacity);
        Assert.Equal("错误", appearance.StatusName);
        Assert.Equal("Error", new MicroLocalization(MicroLanguage.EnUs).Text(appearance.StatusName));
    }
}
