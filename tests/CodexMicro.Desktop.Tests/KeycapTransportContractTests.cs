using System.Text.Json.Nodes;
using AgentController.Adapters.Codex.Windows;
using CodexMicro.Codex;
using CodexMicro.Desktop.Services;
using CodexMicro.Protocol;
using Xunit;

namespace CodexMicro.Desktop.Tests;

// This layer proves Micro's adapter contract. Real wire/native effects have separate tests.
[Trait("Scope", "Keycaps"), Trait("Layer", "L2"), Trait("Boundary", "ControlClientFake")]
public sealed class KeycapTransportContractTests
{
    internal const string ThreadA = "01000000-0000-0000-0000-000000000001";
    internal const string ThreadB = "01000000-0000-0000-0000-000000000002";

    public static IEnumerable<object[]> Routes()
    {
        yield return ["newTask", "CreateDraft", "ACT06"];
        yield return ["forkThread", "ForkThread", "ACT07"];
        yield return ["composer.toggleFastMode", "ToggleFast", "ACT08"];
        yield return ["composer.togglePlanMode", "TogglePlan", "ACT09"];
        yield return ["toggleReviewTab", "OpenReview", "ACT10"];
        yield return ["approval.approve", "ReplyApproval", "ACT11"];
        yield return ["approval.decline", "ReplyApproval", "ACT10_ACT11"];
        yield return ["composer.increaseReasoningEffort", "SetReasoning", "ACT12"];
        yield return ["composer.decreaseReasoningEffort", "SetReasoning", "ACT06"];
        yield return ["turn.cancel", "StopTurn", "ACT07"];
        yield return ["composer.submit", "Submit", "ACT08"];
        yield return ["composer.sketch", "OpenSketch", "ACT09"];
        yield return ["toggleSidebar", "ToggleSidebar", "ACT10"];
        yield return ["navigateBack", "Back", "ACT11"];
        yield return ["navigateForward", "Forward", "ACT10_ACT11"];
    }

    [Theory, MemberData(nameof(Routes)), Trait("Case", "A01-A15")]
    public async Task EveryDeclaredCommandReachesExactlyItsContract(string command, string operation, string slot)
    {
        await using var fixture = new TransportFixture(command, slot);
        var opened = new List<string?>();
        var tiers = new List<(string, string?)>();
        fixture.Transport.ThreadOpened = opened.Add;
        fixture.Transport.ServiceTierApplied = (thread, tier) => tiers.Add((thread, tier));
        var result = await fixture.Transport.TapKeyAsync(slot);
        Assert.Equal(MicroSendDisposition.Accepted, result.Disposition);
        if (Enum.TryParse<CodexUiOperation>(operation, out var uiOperation))
        {
            Assert.Equal(uiOperation, Assert.Single(fixture.Ui.Requests).Operation);
            Assert.Empty(fixture.Control.Requests);
            Assert.Equal(1, fixture.Ui.Applied);
            Assert.Equal(1, fixture.Ui.Guards);
            return;
        }
        var call = Assert.Single(fixture.Control.Effects);
        Assert.Equal(Enum.Parse<CodexOperation>(operation), call.Operation);
        Assert.Empty(fixture.Ui.Requests);
        Assert.Equal(command == "newTask" ? null : ThreadA, call.Arguments["thread_id"]?.GetValue<string>());
        if (command != "newTask") Assert.True(call.Guarded);
        if (command is "approval.approve" or "approval.decline")
        {
            Assert.Equal("approval-1", call.Arguments["request_id"]!.GetValue<string>());
            Assert.Equal(command == "approval.approve" ? "accept" : "decline", call.Arguments["decision"]!.GetValue<string>());
        }
        if (command == "turn.cancel") Assert.Equal("turn-1", call.Arguments["turn_id"]!.GetValue<string>());
        if (command.Contains("ReasoningEffort", StringComparison.Ordinal))
        {
            Assert.Equal(command.Contains("increase", StringComparison.Ordinal) ? "high" : "low", call.Arguments["effort"]!.GetValue<string>());
            Assert.Equal("fixture-model", call.Arguments["expected_model"]!.GetValue<string>());
            Assert.Equal("medium", call.Arguments["expected_effort"]!.GetValue<string>());
            Assert.Equal("priority", call.Arguments["expected_service_tier"]!.GetValue<string>());
            Assert.False(call.Arguments.ContainsKey("model"));
        }
        if (command == "newTask") Assert.Null(Assert.Single(opened));
        else if (command == "forkThread") Assert.Equal(ThreadB, Assert.Single(opened));
        else Assert.Empty(opened);
        if (command == "composer.toggleFastMode") Assert.Equal((ThreadA, "priority"), Assert.Single(tiers));
        else Assert.Empty(tiers);
    }

    [Theory, MemberData(nameof(KeycapCases.SlotCases), MemberType = typeof(KeycapCases)), Trait("Case", "J02")]
    public async Task ActualBindingRatherThanIconOrPositionDeterminesDispatch(string slot)
    {
        await using var fixture = new TransportFixture("newTask", slot);
        var result = await fixture.Transport.SetKeyAsync(slot, pressed: true);
        await fixture.Transport.SetKeyAsync(slot, pressed: false);
        Assert.Equal(MicroSendDisposition.Accepted, result.Disposition);
        Assert.Equal(CodexOperation.CreateDraft, Assert.Single(fixture.Control.Effects).Operation);
        Assert.Empty(fixture.Ui.Requests);
    }

    [Theory, MemberData(nameof(KeycapCases.SlotCases), MemberType = typeof(KeycapCases)), Trait("Case", "A16")]
    public async Task SkillBindingRetainsNameAndPathWithoutSending(string slot)
    {
        await using var fixture = new TransportFixture("newTask", slot);
        var slots = fixture.Context.Layout.Slots.ToDictionary();
        slots[slot] = new("APPR", "composer.submit", new("skill", "review", "C:/synthetic/skills/review/SKILL.md"));
        fixture.Context = fixture.Context with { Layout = fixture.Context.Layout with { Slots = slots } };
        Assert.Equal(MicroSendDisposition.Accepted, (await fixture.Transport.TapKeyAsync(slot)).Disposition);
        Assert.Equal(new(CodexUiOperation.InsertSkill, "review", "C:/synthetic/skills/review/SKILL.md"), Assert.Single(fixture.Ui.Requests));
        Assert.Empty(fixture.Control.Effects);
    }

    [Theory, Trait("Case", "T2-T3")]
    [InlineData("composer.toggleFastMode", "ToggleComposerFast", true)]
    [InlineData("composer.togglePlanMode", "ToggleComposerPlan", true)]
    [InlineData("composer.increaseReasoningEffort", "IncreaseComposerReasoning", true)]
    [InlineData("composer.decreaseReasoningEffort", "DecreaseComposerReasoning", true)]
    [InlineData("composer.toggleFastMode", "ToggleComposerFast", false)]
    [InlineData("composer.togglePlanMode", "ToggleComposerPlan", false)]
    [InlineData("composer.increaseReasoningEffort", "IncreaseComposerReasoning", false)]
    [InlineData("composer.decreaseReasoningEffort", "DecreaseComposerReasoning", false)]
    public async Task OnlyConfirmedComposersUseTheNativeAdapter(string command, string operation, bool draft)
    {
        await using var fixture = new TransportFixture(command);
        fixture.Context = fixture.Context with { ThreadId = null };
        Assert.Equal(MicroSendDisposition.NotSent, (await fixture.Transport.TapKeyAsync("ACT06")).Disposition);
        Assert.Empty(fixture.Ui.Requests);
        var composer = draft ? null : new CodexComposerTarget(1, "selected-item", "composer-1", "picker-1");
        fixture.Context = fixture.Context with { DraftModelPickerId = draft ? "picker-1" : null, ComposerTarget = composer, TargetVersion = 1 };
        Assert.Equal(MicroSendDisposition.Accepted, (await fixture.Transport.TapKeyAsync("ACT06")).Disposition);
        var request = Assert.Single(fixture.Ui.Requests);
        Assert.Equal(Enum.Parse<CodexUiOperation>(operation), request.Operation);
        Assert.Equal(draft ? "picker-1" : null, request.DraftModelPickerId);
        Assert.Equal(composer, request.ComposerTarget);
        Assert.Empty(fixture.Control.Requests);
    }

    [Theory, Trait("Case", "T3"), Trait("Risk", "P0")]
    [InlineData("forkThread")]
    [InlineData("toggleReviewTab")]
    [InlineData("approval.approve")]
    [InlineData("approval.decline")]
    [InlineData("turn.cancel")]
    [InlineData("composer.increaseReasoningEffort")]
    public async Task ThreadDependentCommandsCannotDispatchOnAnUnknownTarget(string command)
    {
        await using var fixture = new TransportFixture(command);
        fixture.Context = fixture.Context with { ThreadId = null };
        Assert.Equal(MicroSendDisposition.NotSent, (await fixture.Transport.TapKeyAsync("ACT06")).Disposition);
        Assert.Empty(fixture.Control.Requests);
        Assert.Empty(fixture.Ui.Requests);
    }

    [Theory, Trait("Case", "A06-A07"), Trait("Risk", "P0")]
    [InlineData("approval.approve", 0)]
    [InlineData("approval.approve", 2)]
    [InlineData("approval.decline", 0)]
    [InlineData("approval.decline", 2)]
    public async Task AmbiguousOrMissingApprovalProducesNoDecision(string command, int count)
    {
        await using var fixture = new TransportFixture(command);
        fixture.Control.State["approvals"] = new JsonArray(Enumerable.Range(0, count)
            .Select(index => (JsonNode)new JsonObject { ["id"] = "approval-" + index }).ToArray());
        Assert.Equal(MicroSendDisposition.Rejected, (await fixture.Transport.TapKeyAsync("ACT06")).Disposition);
        Assert.Empty(fixture.Control.Effects);
    }

    [Theory, Trait("Case", "A08-A09")]
    [InlineData("composer.increaseReasoningEffort", "high")]
    [InlineData("composer.decreaseReasoningEffort", "low")]
    public async Task ReasoningBoundaryDoesNotWriteSettings(string command, string effort)
    {
        await using var fixture = new TransportFixture(command);
        fixture.Control.State["effort"] = effort;
        await fixture.Transport.TapKeyAsync("ACT06");
        Assert.Empty(fixture.Control.Effects);
        Assert.Equal(effort, fixture.Control.State["effort"]!.GetValue<string>());
    }

    [Theory, Trait("Case", "G01-G02"), Trait("Risk", "P0")]
    [InlineData("composer.toggleFastMode", "thread")]
    [InlineData("composer.submit", "thread")]
    [InlineData("composer.togglePlanMode", "draft")]
    [InlineData("composer.toggleFastMode", "draft")]
    [InlineData("composer.toggleFastMode", "composer")]
    [InlineData("composer.togglePlanMode", "composer")]
    public async Task TargetAbaWhileAwaitingValidationCannotMutate(string command, string target)
    {
        await using var fixture = new TransportFixture(command);
        if (target == "draft") fixture.Context = fixture.Context with { ThreadId = null, DraftModelPickerId = "draft-1" };
        if (target == "composer") fixture.Context = fixture.Context with { ThreadId = null,
            ComposerTarget = new(1, "selected-item", "composer-1", "picker-1") };
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Transport.ValidateTargetAsync = (_, _) => { entered.TrySetResult(); return release.Task; };
        var pending = fixture.Transport.TapKeyAsync("ACT06");
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
            Assert.Empty(fixture.Control.Effects);
            Assert.Equal(0, fixture.Ui.Applied);
            var original = fixture.Context;
            fixture.Context = fixture.Context with { ThreadId = ThreadB, TargetVersion = 1 };
            fixture.Context = original with { TargetVersion = 2 };
        }
        finally { release.TrySetResult(true); }
        Assert.NotEqual(MicroSendDisposition.Accepted, (await pending.WaitAsync(TimeSpan.FromSeconds(3))).Disposition);
        Assert.Empty(fixture.Control.Effects);
        Assert.Equal(0, fixture.Ui.Applied);
    }

    [Theory, Trait("Case", "G05"), Trait("Risk", "P0")]
    [InlineData("composer.submit")]
    [InlineData("approval.approve")]
    [InlineData("forkThread")]
    [InlineData("turn.cancel")]
    public async Task NonReversibleActionsRejectRepeatedInputRatherThanQueue(string command)
    {
        await using var fixture = new TransportFixture(command);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Transport.ValidateTargetAsync = (_, _) => { entered.TrySetResult(); return release.Task; };
        var first = fixture.Transport.TapKeyAsync("ACT06");
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
            var extra = await fixture.Transport.TapKeyAsync("ACT06");
            Assert.Equal(MicroSendDisposition.NotSent, extra.Disposition);
            Assert.Equal("action.busy", extra.Detail);
        }
        finally { release.TrySetResult(true); }
        Assert.Equal(MicroSendDisposition.Accepted, (await first.WaitAsync(TimeSpan.FromSeconds(3))).Disposition);
        Assert.Equal(1, fixture.Ui.Applied + fixture.Control.Effects.Count);
    }

    [Theory, Trait("Case", "G06"), Trait("Risk", "P0")]
    [InlineData("negative-receipt", "Rejected")]
    [InlineData("lost-receipt", "OutcomeUnknown")]
    [InlineData("no-ack", "Rejected")]
    public async Task FailedOrUnknownReceiptNeverRetriesAnApproval(string fault, string disposition)
    {
        await using var fixture = new TransportFixture("approval.approve");
        fixture.Control.MutationResponse = _ => fault switch
        {
            "negative-receipt" => JsonNode.Parse("{\"ok\":false}")!,
            "no-ack" => JsonNode.Parse("{\"acknowledged\":false}")!,
            _ => throw new TimeoutException("Synthetic lost receipt after apply"),
        };
        Assert.Equal(Enum.Parse<MicroSendDisposition>(disposition), (await fixture.Transport.TapKeyAsync("ACT06")).Disposition);
        Assert.Single(fixture.Control.Effects);
    }

    [Fact, Trait("Case", "G04"), Trait("Risk", "P0")]
    public async Task DisposalCancelsPendingValidationAndPreventsLaterInputs()
    {
        await using var fixture = new TransportFixture("composer.submit");
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Transport.ValidateTargetAsync = async (_, token) =>
        {
            entered.SetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, token); // Cancellation boundary, not a readiness sleep.
            return true;
        };
        var pending = fixture.Transport.TapKeyAsync("ACT06");
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
        await fixture.Transport.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(3));
        Assert.NotEqual(MicroSendDisposition.Accepted, (await pending).Disposition);
        Assert.Equal(0, fixture.Ui.Applied);
        Assert.True(fixture.Control.Disposed);
        Assert.Equal(MicroSendDisposition.NotSent, (await fixture.Transport.TapKeyAsync("ACT06")).Disposition);
    }

    [Theory, Trait("Case", "E11")]
    [InlineData("unassigned")]
    [InlineData("dictation.pushToTalk")]
    [InlineData("missing-command")]
    public async Task UnsupportedBindingsNeverReachEitherReceiver(string command)
    {
        await using var fixture = new TransportFixture(command);
        Assert.Equal(MicroSendDisposition.NotSent, (await fixture.Transport.TapKeyAsync("ACT06")).Disposition);
        Assert.Empty(fixture.Control.Requests);
        Assert.Empty(fixture.Ui.Requests);
    }

    [Theory, Trait("Case", "G06")]
    [InlineData("Confirmed", "Accepted")]
    [InlineData("NotSent", "NotSent")]
    [InlineData("OutcomeUnknown", "OutcomeUnknown")]
    public async Task NativeDispositionIsPreservedWithoutRetry(string native, string expected)
    {
        await using var fixture = new TransportFixture("composer.submit");
        fixture.Ui.Result = new(Enum.Parse<CodexUiDisposition>(native), "fixture-result");
        var result = await fixture.Transport.TapKeyAsync("ACT06");
        Assert.Equal(Enum.Parse<MicroSendDisposition>(expected), result.Disposition);
        Assert.Equal("fixture-result", result.Detail);
        Assert.Single(fixture.Ui.Requests);
    }

    [Fact, Trait("Case", "G03"), Trait("Risk", "P0")]
    public async Task SixDraftFastInputsWaitInOrderWithoutBeingDropped()
    {
        await using var fixture = new TransportFixture("composer.toggleFastMode");
        fixture.Context = fixture.Context with { ThreadId = null, DraftModelPickerId = "picker-1" };
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var validations = 0;
        fixture.Transport.ValidateTargetAsync = (_, _) =>
        {
            if (Interlocked.Increment(ref validations) == 1) { entered.SetResult(); return release.Task; }
            return Task.FromResult(true);
        };
        var pending = Enumerable.Range(0, 6).Select(_ => fixture.Transport.TapKeyAsync("ACT06")).ToArray();
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
            Assert.Single(fixture.Ui.Requests);
            Assert.Equal(0, fixture.Ui.Applied);
        }
        finally { release.TrySetResult(true); }
        Assert.All(await Task.WhenAll(pending).WaitAsync(TimeSpan.FromSeconds(3)), result => Assert.Equal(MicroSendDisposition.Accepted, result.Disposition));
        Assert.Equal(6, fixture.Ui.Applied);
        Assert.All(fixture.Ui.Requests, request => Assert.Equal(CodexUiOperation.ToggleComposerFast, request.Operation));
    }

    [Fact, Trait("Case", "G04"), Trait("Risk", "P0")]
    public async Task QueuedFastInputsCannotApplyAfterTargetReplacement()
    {
        await using var fixture = new TransportFixture("composer.toggleFastMode");
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Transport.ValidateTargetAsync = (_, _) => { entered.TrySetResult(); return release.Task; };
        var pending = Enumerable.Range(0, 3).Select(_ => fixture.Transport.TapKeyAsync("ACT06")).ToArray();
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
            Assert.Empty(fixture.Control.Effects);
            fixture.Context = fixture.Context with { ThreadId = ThreadB, TargetVersion = 1 };
            fixture.Control.Disconnect();
        }
        finally { release.TrySetResult(true); }
        Assert.All(await Task.WhenAll(pending).WaitAsync(TimeSpan.FromSeconds(3)), result => Assert.NotEqual(MicroSendDisposition.Accepted, result.Disposition));
        Assert.Empty(fixture.Control.Effects);
    }

    [Fact, Trait("Case", "A10"), Trait("Risk", "P0")]
    public async Task MissingActiveTurnCannotStopAnything()
    {
        await using var fixture = new TransportFixture("turn.cancel");
        fixture.Control.State["activeTurnId"] = null;
        Assert.Equal(MicroSendDisposition.Rejected, (await fixture.Transport.TapKeyAsync("ACT06")).Disposition);
        Assert.Empty(fixture.Control.Effects);
    }

    [Theory, Trait("Case", "A08-A09")]
    [InlineData("model", "unlisted-model")]
    [InlineData("effort", "unknown-effort")]
    public async Task UnknownReasoningStateCannotWriteSettings(string field, string value)
    {
        await using var fixture = new TransportFixture("composer.increaseReasoningEffort");
        fixture.Control.State[field] = value;
        Assert.Equal(MicroSendDisposition.Rejected, (await fixture.Transport.TapKeyAsync("ACT06")).Disposition);
        Assert.Empty(fixture.Control.Effects);
    }

    [Theory]
    [InlineData("AG05")]
    [InlineData("not-a-slot")]
    public async Task EmptyAndUnknownControlsHaveNoEffect(string control)
    {
        await using var fixture = new TransportFixture("newTask");
        Assert.Equal(MicroSendDisposition.NotSent, (await fixture.Transport.TapKeyAsync(control)).Disposition);
        Assert.Empty(fixture.Control.Requests);
        Assert.Empty(fixture.Ui.Requests);
    }

    internal sealed class TransportFixture : IAsyncDisposable
    {
        internal RecordingControl Control { get; } = new();
        internal RecordingUi Ui { get; } = new();
        internal SoftwareMicroTransport Transport { get; }
        internal MicroControlContext Context;
        internal TransportFixture(string command, string slot = "ACT06")
        {
            var slots = CodexMicroLayoutObserver.DefaultSlots.ToDictionary();
            slots[slot] = new(slot == "ACT10_ACT11" ? "MIC" : "APPR", null, new("command", command));
            Context = new(ThreadA, new Dictionary<string, string>(),
                new(slots, "composer-navigation", new Dictionary<string, string>(), "synthetic", SeparateMicrophoneKeys: slot != "ACT10_ACT11"),
                MicroProfileSettings.CreateTransient(modelsCachePath: Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".missing-models")).Current);
            Transport = new(Control, Ui) { CaptureContext = () => Context };
        }
        public ValueTask DisposeAsync() => Transport.DisposeAsync();
    }

    internal sealed record Call(CodexOperation Operation, JsonObject Arguments, bool Guarded);
    internal sealed class RecordingControl : ICodexControlClient
    {
        public event Action? Disconnected;
        internal List<Call> Requests { get; } = [];
        internal List<Call> Effects { get; } = [];
        internal bool Disposed;
        internal JsonObject State = JsonNode.Parse("""
            {"model":"fixture-model","effort":"medium","serviceTier":"priority","activeTurnId":"turn-1","approvals":[{"id":"approval-1"}]}
            """)!.AsObject();
        internal Func<CodexOperation, JsonNode>? MutationResponse;
        public Task ConnectAsync(CancellationToken cancellationToken = default) { cancellationToken.ThrowIfCancellationRequested(); return Task.CompletedTask; }
        public async Task<JsonNode> ExecuteAsync(CodexOperation operation, JsonObject arguments,
            CancellationToken cancellationToken = default, Func<Task<bool>>? canApply = null)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var call = new Call(operation, (JsonObject)arguments.DeepClone(), canApply is not null);
            Requests.Add(call);
            if (canApply is not null && !await canApply()) throw new InvalidOperationException("Synthetic receiver rejected stale target");
            cancellationToken.ThrowIfCancellationRequested();
            if (operation == CodexOperation.ReadThreadState) return State.DeepClone();
            if (operation == CodexOperation.ListModels) return JsonNode.Parse("""
                {"data":[{"model":"fixture-model","supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"medium"},{"reasoningEffort":"high"}]}]}
                """)!;
            // Only explicitly modeled operations can be acknowledged.
            var reply = operation switch
            {
                CodexOperation.CreateDraft or CodexOperation.OpenReview or CodexOperation.TogglePlan or
                    CodexOperation.SetReasoning or CodexOperation.StopTurn => new JsonObject { ["ok"] = true },
                CodexOperation.ForkThread => new JsonObject { ["threadId"] = ThreadB },
                CodexOperation.ToggleFast => JsonNode.Parse("{\"settings\":{\"serviceTier\":\"priority\"}}")!,
                CodexOperation.ReplyApproval => new JsonObject { ["acknowledged"] = true },
                _ => throw new Xunit.Sdk.XunitException("Unmodeled receiver operation: " + operation),
            };
            Effects.Add(call);
            return MutationResponse?.Invoke(operation) ?? reply;
        }
        internal void Disconnect() => Disconnected?.Invoke();
        public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
    }

    internal sealed class RecordingUi : ICodexUiController
    {
        internal List<CodexUiRequest> Requests { get; } = [];
        internal int Applied;
        internal int Guards;
        internal CodexUiResult Result = new(CodexUiDisposition.Confirmed, "synthetic-confirmed");
        public async Task<CodexUiResult> ExecuteAsync(CodexUiRequest request,
            Func<CancellationToken, Task<bool>>? canApply = null, CancellationToken cancellationToken = default)
        {
            Requests.Add(request);
            Assert.NotNull(canApply);
            Guards++;
            if (!await canApply(cancellationToken)) return new(CodexUiDisposition.NotSent, "target-changed");
            cancellationToken.ThrowIfCancellationRequested();
            Applied++;
            return Result;
        }
    }
}
