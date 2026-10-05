using System.Windows;
using AgentController.Adapters.Codex.Windows;
using Xunit;

namespace CodexMicro.Desktop.Tests;

// Uses the referenced production controller; only OS observations/mutations are synthetic.
[Trait("Scope", "Keycaps"), Trait("Layer", "L2"), Trait("Boundary", "SyntheticNativeDesktop")]
public sealed class KeycapNativeAdapterTests
{
    [Theory]
    [InlineData("Submit", "send")]
    [InlineData("ToggleSidebar", "sidebar")]
    [InlineData("Back", "back")]
    [InlineData("Forward", "forward")]
    [InlineData("OpenSketch", "sketch")]
    public async Task NativeCommandsRequireOneMutationAndAnObservedEffect(string operation, string expectedInput)
    {
        var desktop = new Desktop();
        desktop.Apply = id => desktop.State = id switch
        {
            "send" => desktop.State with { Busy = true, Composer = desktop.State.Composer! with { Text = "" } },
            "sidebar" => desktop.State with { Sidebar = desktop.State.Sidebar! with { Name = "Hide sidebar" } },
            "back" => desktop.State with { Route = "previous" },
            "forward" => desktop.State with { Route = "next" },
            "sketch" => desktop.State with { SketchEditorOpen = true },
            _ => throw new Xunit.Sdk.XunitException("Unexpected native input: " + id),
        };
        using var controller = new CodexUiController(desktop);
        var result = await controller.ExecuteAsync(new(Enum.Parse<CodexUiOperation>(operation)), _ => Task.FromResult(true));
        Assert.Equal(CodexUiDisposition.Confirmed, result.Disposition);
        Assert.Equal(expectedInput, Assert.Single(desktop.Inputs));
        Assert.True(desktop.Released);
    }

    [Theory, Trait("Case", "G06"), Trait("Risk", "P0")]
    [InlineData("Submit")]
    [InlineData("OpenSketch")]
    [InlineData("ToggleSidebar")]
    public async Task CancellationAfterMutationIsUnknownAndNeverRepeatsInput(string operation)
    {
        var desktop = new Desktop();
        using var cancellation = new CancellationTokenSource();
        desktop.Apply = _ => cancellation.Cancel();
        using var controller = new CodexUiController(desktop);
        var result = await controller.ExecuteAsync(new(Enum.Parse<CodexUiOperation>(operation)), cancellationToken: cancellation.Token);
        Assert.Equal(CodexUiDisposition.OutcomeUnknown, result.Disposition);
        Assert.Single(desktop.Inputs);
    }

    [Theory, Trait("Case", "G01"), Trait("Risk", "P0")]
    [InlineData("route")]
    [InlineData("composer")]
    [InlineData("text")]
    [InlineData("foreground")]
    public async Task ChangedNativeTargetOrTextBeforeDispatchProducesNoInput(string change)
    {
        var desktop = new Desktop();
        using var controller = new CodexUiController(desktop);
        var result = await controller.ExecuteAsync(new(CodexUiOperation.Submit), _ =>
        {
            if (change == "foreground") desktop.IsCurrent = false;
            else desktop.State = change switch
            {
                "route" => desktop.State with { Route = "different" },
                "composer" => desktop.State with { Composer = desktop.State.Composer! with { Id = "replacement" } },
                _ => desktop.State with { Composer = desktop.State.Composer! with { Text = "newer draft" } },
            };
            return Task.FromResult(true);
        });
        Assert.Equal(CodexUiDisposition.NotSent, result.Disposition);
        Assert.Empty(desktop.Inputs);
    }

    [Theory, Trait("Case", "A11")]
    [InlineData("disabled")]
    [InlineData("no-composer")]
    [InlineData("other-menu")]
    public async Task UnavailableSubmitDoesNotInvokeAnything(string condition)
    {
        var desktop = new Desktop();
        desktop.State = condition switch
        {
            "disabled" => desktop.State with { Send = desktop.State.Send! with { Enabled = false } },
            "no-composer" => desktop.State with { Composer = null },
            _ => desktop.State with { UnrelatedMenuOpen = true },
        };
        using var controller = new CodexUiController(desktop);
        Assert.Equal(CodexUiDisposition.NotSent, (await controller.ExecuteAsync(new(CodexUiOperation.Submit))).Disposition);
        Assert.Empty(desktop.Inputs);
    }

    [Theory, Trait("Case", "A03-A04")]
    [InlineData("Enable fast mode", "Enable standard mode", "Plan", true, false)]
    [InlineData("启用快速模式", "启用标准模式", "计划", false, false)]
    [InlineData("啟用快速模式", "啟用標準模式", "計劃", true, false)]
    [InlineData("Enable fast mode", "Enable standard mode", "Plan", true, true)]
    [InlineData("启用快速模式", "启用标准模式", "计划", false, true)]
    [InlineData("啟用快速模式", "啟用標準模式", "計劃", true, true)]
    public async Task NativeModesPreserveTextAndAttachmentsInDraftsAndExistingChats(string fastLabel, string standardLabel, string planIndicator, bool draft, bool speedInsidePicker)
    {
        var desktop = new Desktop();
        var attachment = Desktop.Node("attachment");
        var picker = Desktop.Node("picker") with { AutomationId = "model-picker", Expanded = false };
        var speedControl = Desktop.Node("fast") with { Name = fastLabel };
        desktop.State = desktop.State with { IsDraft = draft, Busy = !draft, ComposerControls = [picker, attachment],
            ModeControls = speedInsidePicker ? [] : [speedControl] };
        desktop.Apply = id =>
        {
            if (id is "picker" or "close-picker")
            {
                Assert.True(speedInsidePicker);
                picker = picker with { Expanded = id == "picker" };
                desktop.State = desktop.State with { ComposerControls = [picker, attachment],
                    ModeControls = id == "picker" ? [speedControl] : [] };
                return;
            }
            Assert.Equal("F20", id);
            Assert.Single(desktop.State.ModeControls!);
            speedControl = speedControl with { Name = speedControl.Name == fastLabel ? standardLabel : fastLabel };
            desktop.State = desktop.State with { ModeControls = [speedControl] };
        };
        using var controller = new CodexUiController(desktop);
        var enable = await controller.ExecuteAsync(new(CodexUiOperation.ToggleComposerFast, DraftModelPickerId: "model-picker"));
        var disable = await controller.ExecuteAsync(new(CodexUiOperation.ToggleComposerFast, DraftModelPickerId: "model-picker"));
        Assert.Equal(CodexUiDisposition.Confirmed, enable.Disposition);
        Assert.True(enable.FastEnabled);
        Assert.Equal(CodexUiDisposition.Confirmed, disable.Disposition);
        Assert.False(disable.FastEnabled);
        Assert.Equal(speedInsidePicker ? ["picker", "F20", "close-picker", "picker", "F20", "close-picker"] : new[] { "F20", "F20" }, desktop.Inputs);
        Assert.False(picker.Expanded);

        desktop.Inputs.Clear();
        desktop.State = desktop.State with { ModeControls = [] };
        desktop.Apply = id =>
        {
            Assert.Equal("F19", id);
            desktop.State = desktop.State with { ModeControls = desktop.State.ModeControls!.Count == 0
                ? [Desktop.Node("plan-indicator") with { Name = planIndicator }] : [] };
        };
        Assert.Equal(CodexUiDisposition.Confirmed, (await controller.ExecuteAsync(new(CodexUiOperation.ToggleComposerPlan, DraftModelPickerId: "model-picker"))).Disposition);
        Assert.Equal(CodexUiDisposition.Confirmed, (await controller.ExecuteAsync(new(CodexUiOperation.ToggleComposerPlan, DraftModelPickerId: "model-picker"))).Disposition);
        Assert.Equal("draft text", desktop.State.Composer!.Text);
        Assert.Contains(attachment, desktop.State.ComposerControls);
        Assert.Equal(new[] { "F19", "F19" }, desktop.Inputs);
    }

    [Fact, Trait("Case", "A12")]
    public async Task AlreadyOpenSketchDoesNotInvokeAgain()
    {
        var desktop = new Desktop();
        desktop.State = desktop.State with { SketchEditorOpen = true };
        using var controller = new CodexUiController(desktop);
        Assert.Equal(CodexUiDisposition.Confirmed, (await controller.ExecuteAsync(new(CodexUiOperation.OpenSketch))).Disposition);
        Assert.Empty(desktop.Inputs);
    }

    private sealed class Desktop : ICodexUiDesktop, ICodexUiSession
    {
        internal static UiNode Node(string id) => new(id, null, UiRole.Button, id, "synthetic", new Rect(0, 0, 50, 25), Invokable: true);
        internal UiState State = new("chat", Node("composer") with { Role = UiRole.Editor, Text = "draft text" },
            Node("send"), Node("sidebar") with { Name = "Show sidebar" }, null, [], [], false,
            HistoryBack: Node("back"), HistoryForward: Node("forward"), SketchMenuItem: Node("sketch"));
        internal List<string> Inputs { get; } = [];
        internal Action<string> Apply = id => throw new Xunit.Sdk.XunitException("Unmodeled input: " + id);
        internal bool Released;
        public bool IsCurrent { get; set; } = true;
        public ICodexUiSession Capture() { Released = false; return this; }
        public Task<CodexCommandBinding> ReadCommandBindingAsync(string command, CancellationToken token) =>
            Task.FromResult(new CodexCommandBinding(CodexCommandShortcut.Parse(command switch
            {
                "composer.toggleFastMode" => "F20", "composer.togglePlanMode" => "F19",
                "composer.increaseReasoningEffort" => "F18", "composer.decreaseReasoningEffort" => "F17",
                _ => throw new Xunit.Sdk.XunitException("Unexpected command: " + command),
            }), null));
        public UiState Read() => State;
        public void Invoke(string id) { Inputs.Add(id); Apply(id); }
        public void Navigate(bool forward) => Invoke(forward ? "forward" : "back");
        public void Focus(string id) => throw new Xunit.Sdk.XunitException("Unexpected focus: " + id);
        public void Scroll(string id, CodexUiOperation operation) => throw new Xunit.Sdk.XunitException("Unexpected scroll");
        public bool InsertSkill(string composerId, string name, string path, CancellationToken token) =>
            throw new Xunit.Sdk.XunitException("Unexpected skill insertion");
        public void SendComposerShortcut(UiState target, CodexCommandShortcut shortcut, CancellationToken token, string? openModelPickerId = null)
        {
            token.ThrowIfCancellationRequested();
            Assert.Equal(State.Composer, target.Composer);
            if (openModelPickerId is not null)
                Assert.True(State.ComposerControls.Single(node => node.AutomationId == openModelPickerId).Expanded);
            else Assert.DoesNotContain(State.ComposerControls, node => node.Expanded == true);
            Invoke("F" + (shortcut.Key - 0x70 + 1));
        }
        public void CloseModelPicker(UiState target, string pickerId, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            Assert.Equal(State.Composer, target.Composer);
            Assert.True(State.ComposerControls.Single(node => node.AutomationId == pickerId).Expanded);
            Invoke("close-picker");
        }
        public void Dispose() => Released = true;
    }
}
