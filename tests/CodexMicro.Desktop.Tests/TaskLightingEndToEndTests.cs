using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using CodexMicro.Codex;
using CodexMicro.Core.Models;
using CodexMicro.Desktop.Services;
using CodexMicro.Protocol;
using Xunit;

namespace CodexMicro.Desktop.Tests;

[Collection(WpfUiCollection.Name)]
[Trait("Category", "BehaviorAcceptance"), Trait("Scope", "TaskLighting")]
[Trait("Layer", "E2E"), Trait("Boundary", "IsolatedNamedPipeAndFilesToWpf")]
public sealed class TaskLightingEndToEndTests
{
    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public Task OwnerRediscoveryUsesAuthoritativeIdleWithoutInventingErrors(bool monitorPage, bool selected) =>
        KeycapUiThread.Run(async () =>
        {
            await using var fixture = await TaskLightingFixture.CreateAsync();
            var persisted = await File.ReadAllTextAsync(fixture.RolloutPath);
            var monitor = fixture.CreateMonitor();
            await using var rig = new BehaviorAcceptanceRig("composer-navigation", "turn.cancel");
            await rig.ConnectAsync();
            await monitor.ReadAsync(CancellationToken.None);
            await using var observer = new SoftwareThreadObserver(rig.CreateActivityConnection());
            var disconnected = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var resumed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            observer.ActivityChanged += observation =>
            {
                var task = Assert.Single(monitor.ObserveActivity(observation)!.Tasks);
                if (task.Status == ThreadStatus.Unknown) disconnected.TrySetResult();
                if (disconnected.Task.IsCompleted && task.Status == ThreadStatus.Thinking) resumed.TrySetResult();
            };
            await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
            var window = new MicroSurfaceWindow(new(MicroLanguage.EnUs),
                profileSettings: MicroProfileSettings.CreateTransient(modelsCachePath: fixture.ModelsPath),
                transport: rig.Transport,
                activateSoftwareApplication: () => Task.FromResult(true),
                readSoftwareSelection: _ => Task.FromResult<string?>(TaskLightingFixture.ThreadId));
            try
            {
                if (selected) window.SelectSoftwareThread(TaskLightingFixture.ThreadId);
                typeof(MicroSurfaceWindow).GetField("_monitorPage", BindingFlags.Instance | BindingFlags.NonPublic)!
                    .SetValue(window, monitorPage);
                window.ControlGrid.Visibility = monitorPage ? Visibility.Collapsed : Visibility.Visible;
                window.MonitorGrid.Visibility = monitorPage ? Visibility.Visible : Visibility.Collapsed;
                await AssertLightAsync(ThreadStatus.Thinking, Color.FromRgb(0x30, 0x4F, 0xFE));

                await rig.RestartOwnerAsync();
                await disconnected.Task.WaitAsync(TimeSpan.FromSeconds(5));
                for (var poll = 0; poll < 2; poll++)
                {
                    await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
                    await AssertLightAsync(ThreadStatus.Unknown);
                }
                // Fresh owner state resolves missing observation; a listener
                // cannot infer a failed task from a disconnected IPC client.
                rig.RestoreIdleOwner();
                await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
                await AssertLightAsync(ThreadStatus.Idle);
                await rig.ResumeTaskAsync();
                await resumed.Task.WaitAsync(TimeSpan.FromSeconds(5));
                await AssertLightAsync(ThreadStatus.Thinking, Color.FromRgb(0x30, 0x4F, 0xFE));
                Assert.Empty(rig.DesktopRequests);
                Assert.Equal(persisted, await File.ReadAllTextAsync(fixture.RolloutPath));
            }
            finally { await window.CloseForApplicationExitAsync(); }

            async Task AssertLightAsync(ThreadStatus expected, Color? color = null)
            {
                var snapshot = Assert.IsType<CodexTaskMonitorSnapshot>(await monitor.ReadAsync(CancellationToken.None));
                var task = Assert.Single(snapshot.Tasks);
                Assert.Equal(expected, task.Status);
                Assert.Null(task.ErrorCode);
                Assert.False(task.HasPendingQuestion);
                typeof(MicroSurfaceWindow).GetMethod("ApplyMonitorSnapshot", BindingFlags.Instance | BindingFlags.NonPublic)!
                    .Invoke(window, [snapshot]);
                await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
                var key = monitorPage ? window.MonitorGrid.Children.OfType<Button>().Single(button =>
                    AutomationProperties.GetName(button) == TaskLightingFixture.Title) : window.AgentKey0;
                Assert.True(key.IsEnabled);
                Assert.Equal(TaskLightingFixture.Title, AutomationProperties.GetName(key));
                key.ApplyTemplate();
                var field = Assert.IsType<Ellipse>(key.Template.FindName("StatusLightField", key));
                var brush = Assert.IsType<SolidColorBrush>(field.Fill);
                if (color is { } litColor) Assert.Equal(litColor, brush.Color);
                else if (selected) Assert.Equal(Colors.White, brush.Color);
                Assert.Equal(selected ? 1 : color.HasValue ? 0.94 : 0, brush.Opacity);
                Assert.DoesNotContain("Error", AutomationProperties.GetItemStatus(key));
            }
        });

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public Task RecreatingOnlyMicroMonitoringRestoresTheSameRunningTask(bool monitorPage, bool selected) =>
        KeycapUiThread.Run(async () =>
        {
            await using var fixture = await TaskLightingFixture.CreateAsync();
            var persisted = await File.ReadAllTextAsync(fixture.RolloutPath);
            await using var rig = new BehaviorAcceptanceRig("composer-navigation", "turn.cancel");
            await rig.ConnectAsync();
            var window = new MicroSurfaceWindow(new(MicroLanguage.EnUs),
                profileSettings: MicroProfileSettings.CreateTransient(modelsCachePath: fixture.ModelsPath),
                transport: rig.Transport,
                activateSoftwareApplication: () => Task.FromResult(true),
                readSoftwareSelection: _ => Task.FromResult<string?>(TaskLightingFixture.ThreadId));
            try
            {
                if (selected) window.SelectSoftwareThread(TaskLightingFixture.ThreadId);
                typeof(MicroSurfaceWindow).GetField("_monitorPage", BindingFlags.Instance | BindingFlags.NonPublic)!
                    .SetValue(window, monitorPage);
                window.ControlGrid.Visibility = monitorPage ? Visibility.Collapsed : Visibility.Visible;
                window.MonitorGrid.Visibility = monitorPage ? Visibility.Visible : Visibility.Collapsed;
                // Dispose/recreate only Micro's monitor, listener and pipe client.
                // The owner, its turn and the rollout stay unchanged throughout.
                for (var launch = 0; launch < 2; launch++)
                {
                    var monitor = fixture.CreateMonitor();
                    var initial = Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks);
                    Assert.Equal(ThreadStatus.Unknown, initial.Status);
                    Assert.Null(initial.ErrorCode);
                    await using var observer = new SoftwareThreadObserver(rig.CreateActivityConnection());
                    var observed = new System.Collections.Concurrent.ConcurrentQueue<CodexMonitoredTask>();
                    observer.ActivityChanged += observation =>
                        observed.Enqueue(Assert.Single(monitor.ObserveActivity(observation)!.Tasks));
                    await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
                    var running = Assert.IsType<CodexTaskMonitorSnapshot>(await monitor.ReadAsync(CancellationToken.None));
                    Assert.Equal(ThreadStatus.Thinking, Assert.Single(running.Tasks).Status);
                    Assert.Equal(TaskLightingFixture.TurnId,
                        (await rig.ReadDesktopStateAsync())["activeTurnId"]!.GetValue<string>());
                    typeof(MicroSurfaceWindow).GetMethod("ApplyMonitorSnapshot", BindingFlags.Instance | BindingFlags.NonPublic)!
                        .Invoke(window, [running]);
                    await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
                    var key = monitorPage ? window.MonitorGrid.Children.OfType<Button>().Single(button =>
                        AutomationProperties.GetName(button) == TaskLightingFixture.Title) : window.AgentKey0;
                    Assert.True(key.IsEnabled);
                    Assert.Equal(TaskLightingFixture.Title, AutomationProperties.GetName(key));
                    key.ApplyTemplate();
                    var field = Assert.IsType<Ellipse>(key.Template.FindName("StatusLightField", key));
                    var brush = Assert.IsType<SolidColorBrush>(field.Fill);
                    Assert.Equal(Color.FromRgb(0x30, 0x4F, 0xFE), brush.Color);
                    Assert.Equal(selected ? 1 : 0.94, brush.Opacity);
                    await observer.DisposeAsync();
                    Assert.NotEmpty(observed);
                    Assert.All(observed, task =>
                    {
                        Assert.NotEqual(ThreadStatus.Error, task.Status);
                        Assert.Null(task.ErrorCode);
                    });
                }
                Assert.Empty(rig.DesktopRequests);
                Assert.Equal(persisted, await File.ReadAllTextAsync(fixture.RolloutPath));
            }
            finally { await window.CloseForApplicationExitAsync(); }
        });

    // In-process feature E2E: real stop dispatch and IPC readback against an
    // isolated owner, plus persisted Codex data -> monitor -> real XAML keys.
    // It does not cover the installed Codex process, scheduling or OS input.
    // The window stays unloaded; no real Codex, UIA, hooks or background services start.
    [Theory]
    [InlineData(false, false, false)]
    [InlineData(false, true, false)]
    [InlineData(true, false, false)]
    [InlineData(true, true, false)]
    [InlineData(false, false, true)]
    [InlineData(false, true, true)]
    [InlineData(true, false, true)]
    [InlineData(true, true, true)]
    public Task StoppedTaskDoesNotLightBlueAfterMonitorRecreationEvenWhenTheStopWasNotPersisted(
        bool monitorPage, bool selected, bool persistStop) =>
        KeycapUiThread.Run(async () =>
        {
            await using var fixture = await TaskLightingFixture.CreateAsync();
            var observations = new List<(Color Color, double Opacity, string Status)>();
            for (var launch = 0; launch < 2; launch++)
            {
                var monitor = fixture.CreateMonitor();
                await using var rig = new BehaviorAcceptanceRig("composer-navigation", "turn.cancel");
                await rig.ConnectAsync();
                await monitor.ReadAsync(CancellationToken.None);
                await using var observer = new SoftwareThreadObserver(rig.CreateActivityConnection());
                var idle = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var resumed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                observer.ActivityChanged += observation =>
                {
                    monitor.ObserveActivity(observation);
                    if (observation.Activity.Status == ThreadStatus.Idle) idle.TrySetResult();
                    if (idle.Task.IsCompleted && observation.Activity.Status == ThreadStatus.Thinking) resumed.TrySetResult();
                };
                await observer.RefreshAsync([TaskLightingFixture.ThreadId]);
                Assert.Equal(ThreadStatus.Thinking, Assert.Single((await monitor.ReadAsync(CancellationToken.None))!.Tasks).Status);
                var beforeStop = await rig.ReadDesktopStateAsync();
                Assert.Equal(TaskLightingFixture.TurnId, beforeStop["activeTurnId"]!.GetValue<string>());
                Assert.Equal(MicroSendDisposition.Accepted, (await rig.Transport.TapKeyAsync("ACT06")).Disposition);
                await idle.Task.WaitAsync(TimeSpan.FromSeconds(5));
                var stopped = await rig.ReadDesktopStateAsync();
                Assert.Equal(TaskLightingFixture.ThreadId, stopped["threadId"]!.GetValue<string>());
                Assert.Null(stopped["activeTurnId"]);
                Assert.Single(rig.DesktopRequests);
                // The positive control uses the same pipeline and assertions;
                // only the presence of Codex's terminal record differs.
                if (persistStop && launch == 0)
                    await fixture.AppendAsync(new { type = "turn_aborted", turn_id = TaskLightingFixture.TurnId });
                var persisted = await File.ReadAllTextAsync(fixture.RolloutPath);
                var window = new MicroSurfaceWindow(new(MicroLanguage.EnUs),
                    profileSettings: MicroProfileSettings.CreateTransient(modelsCachePath: fixture.ModelsPath),
                    transport: rig.Transport,
                    activateSoftwareApplication: () => Task.FromResult(true),
                    readSoftwareSelection: _ => Task.FromResult<string?>(TaskLightingFixture.ThreadId));
                try
                {
                    if (selected) window.SelectSoftwareThread(TaskLightingFixture.ThreadId);
                    // Set only the view mode: a hidden window intentionally ignores
                    // navigation clicks. Status and lighting are never seeded by the test.
                    typeof(MicroSurfaceWindow).GetField("_monitorPage", BindingFlags.Instance | BindingFlags.NonPublic)!
                        .SetValue(window, monitorPage);
                    window.ControlGrid.Visibility = monitorPage ? Visibility.Collapsed : Visibility.Visible;
                    window.MonitorGrid.Visibility = monitorPage ? Visibility.Visible : Visibility.Collapsed;

                    for (var poll = 0; poll < 2; poll++)
                    {
                        var snapshot = Assert.IsType<CodexTaskMonitorSnapshot>(
                            await monitor.ReadAsync(CancellationToken.None));
                        // Deliver the unmodified result through the same ingress used
                        // by RefreshMonitorAsync; replace scheduling, not state policy.
                        typeof(MicroSurfaceWindow).GetMethod("ApplyMonitorSnapshot", BindingFlags.Instance | BindingFlags.NonPublic)!
                            .Invoke(window, [snapshot]);
                        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);

                        var key = monitorPage
                            ? window.MonitorGrid.Children.OfType<Button>().Single(button =>
                                AutomationProperties.GetName(button) == TaskLightingFixture.Title)
                            : window.AgentKey0;
                        Assert.Equal(TaskLightingFixture.Title, AutomationProperties.GetName(key));
                        Assert.True(key.IsEnabled);
                        key.ApplyTemplate();
                        var field = Assert.IsType<Ellipse>(key.Template.FindName("StatusLightField", key));
                        var brush = Assert.IsType<SolidColorBrush>(field.Fill);
                        Assert.Same(key.BorderBrush, brush);
                        observations.Add((brush.Color, brush.Opacity, AutomationProperties.GetItemStatus(key)));
                    }
                    Assert.Equal(persisted, await File.ReadAllTextAsync(fixture.RolloutPath));

                    // The same IPC -> monitor -> WPF path must still light blue
                    // when a new live turn begins, even before rollout catches up.
                    await rig.ResumeTaskAsync();
                    await resumed.Task.WaitAsync(TimeSpan.FromSeconds(5));
                    var running = Assert.IsType<CodexTaskMonitorSnapshot>(await monitor.ReadAsync(CancellationToken.None));
                    typeof(MicroSurfaceWindow).GetMethod("ApplyMonitorSnapshot", BindingFlags.Instance | BindingFlags.NonPublic)!
                        .Invoke(window, [running]);
                    await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
                    var runningKey = monitorPage
                        ? window.MonitorGrid.Children.OfType<Button>().Single(button =>
                            AutomationProperties.GetName(button) == TaskLightingFixture.Title)
                        : window.AgentKey0;
                    runningKey.ApplyTemplate();
                    var runningField = Assert.IsType<Ellipse>(runningKey.Template.FindName("StatusLightField", runningKey));
                    var runningBrush = Assert.IsType<SolidColorBrush>(runningField.Fill);
                    Assert.Equal(Color.FromRgb(0x30, 0x4F, 0xFE), runningBrush.Color);
                    Assert.Equal(selected ? 1 : 0.94, runningBrush.Opacity);
                }
                finally { await window.CloseForApplicationExitAsync(); }
            }

            Assert.Equal(4, observations.Count);
            Assert.All(observations, observation =>
            {
                Assert.False(observation.Color == Color.FromRgb(0x30, 0x4F, 0xFE) && observation.Opacity > 0,
                    $"Stopped task still lights {(monitorPage ? "monitor" : "control")} key blue " +
                    $"after monitor recreation/poll (selected={selected}, persistedStop={persistStop}, status={observation.Status}).");
                Assert.Equal(selected ? 1 : 0, observation.Opacity);
                if (selected) Assert.Equal(Colors.White, observation.Color);
            });
        });
}
