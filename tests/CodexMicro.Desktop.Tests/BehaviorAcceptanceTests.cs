using CodexMicro.Desktop.Services;
using CodexMicro.Protocol;
using Xunit;

namespace CodexMicro.Desktop.Tests;

[Trait("Category", "BehaviorAcceptance")]
public sealed class BehaviorAcceptanceTests
{
    [Theory, MemberData(nameof(KeycapCases.SlotCases), MemberType = typeof(KeycapCases))]
    [Trait("Scope", "Keycaps"), Trait("Layer", "L2"), Trait("Boundary", "NamedPipe"), Trait("Case", "A10")]
    public async Task RemappedStopUsesTheRealWireProtocolAtEverySlot(string slot)
    {
        await using var rig = new BehaviorAcceptanceRig("composer-navigation", "turn.cancel", slot);
        await rig.ConnectAsync();
        var result = await rig.Transport.TapKeyAsync(slot);
        Assert.Equal(MicroSendDisposition.Accepted, result.Disposition);
        var request = Assert.Single(rig.DesktopRequests);
        Assert.Equal("thread-follower-interrupt-turn", request["method"]!.GetValue<string>());
        Assert.Equal("01000000-0000-0000-0000-000000000001", request["params"]!["conversationId"]!.GetValue<string>());
        Assert.Equal("fixture-turn", request["params"]!["expectedTurnId"]!.GetValue<string>());
        Assert.Equal("user-stop", request["params"]!["mode"]!.GetValue<string>());
    }

    // The same input and minimum outcome apply to both transports.
    [Theory]
    [InlineData("submit", "ACT12", "composer-navigation", null)]
    [InlineData("composer-choice", "ENC", "composer-navigation", null)]
    [InlineData("scroll-forward", "wheel+", "conversation-scroll", null)]
    [InlineData("scroll-backward", "wheel-", "conversation-scroll", null)]
    [InlineData("plan", "up", "composer-navigation", null)]
    [InlineData("sidebar", "down", "composer-navigation", null)]
    [InlineData("history-back", "left", "composer-navigation", null)]
    [InlineData("history-forward", "right", "composer-navigation", null)]
    [InlineData("custom-review", "ACT06", "composer-navigation", "toggleReviewTab")]
    [InlineData("insert-skill", "ACT06", "composer-navigation", "skill")]
    [InlineData("stop-active-turn", "ACT06", "composer-navigation", "turn.cancel")]
    public async Task ConfiguredControlMustReachTheExternalControlBoundary(
        string scenario, string gesture, string mode, string? binding)
    {
        await using var rig = new BehaviorAcceptanceRig(mode, binding);
        await rig.ConnectAsync();

        var result = gesture switch
        {
            "wheel+" => await rig.Transport.StepEncoderAsync(true),
            "wheel-" => await rig.Transport.StepEncoderAsync(false),
            "up" => await rig.Transport.MoveJoystickAsync(0, 1, "up"),
            "right" => await rig.Transport.MoveJoystickAsync(.25, 1, "right"),
            "down" => await rig.Transport.MoveJoystickAsync(.5, 1, "down"),
            "left" => await rig.Transport.MoveJoystickAsync(.75, 1, "left"),
            _ => await rig.Transport.TapKeyAsync(gesture),
        };

        Assert.True(result.Disposition == MicroSendDisposition.Accepted,
            $"{scenario}: input was not dispatched ({result.Disposition}): {result.Detail}");
        Assert.True(rig.SawControlInput(gesture, binding), $"{scenario}: receiver observed no corresponding input");
    }
}
