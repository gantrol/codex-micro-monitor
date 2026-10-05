using CodexMicro.Desktop.Services;
using Xunit;

namespace CodexMicro.Desktop.Tests;

[Trait("Scope", "Keycaps"), Trait("Layer", "L0")]
public sealed class KeycapCatalogContractTests
{
    [Theory, MemberData(nameof(KeycapCases.CatalogCases), MemberType = typeof(KeycapCases))]
    public void CatalogPreservesEachIdentityDefaultActionAndWidth(string id, string action, string width)
    {
        var item = CodexKeycapCatalog.Get(id);
        Assert.True(CodexKeycapCatalog.IsKnown(id));
        Assert.Equal(id, item.IconId);
        Assert.Equal(action, item.DefaultAction);
        Assert.Equal(width, item.Size);
        Assert.Equal(KeycapCases.Commands.Contains(action), CodexActionCatalog.SoftwareRoute(action) is not null);
    }

    [Fact]
    public void CatalogAndSupportedCommandInventoriesHaveNoUnreviewedAdditionsOrDuplicates()
    {
        Assert.Equal(KeycapCases.CatalogCases().Select(row => (string)row[0]).Order(), CodexKeycapCatalog.KnownIds.Order());
        Assert.Equal(KeycapCases.Commands.Order(), CodexActionCatalog.All.Where(c => c.SoftwareSupported).Select(c => c.Id).Order());
        Assert.Equal(CodexActionCatalog.All.Count(), CodexActionCatalog.All.Select(c => c.Id).Distinct().Count());
    }

    [Theory, MemberData(nameof(KeycapCases.SlotCases), MemberType = typeof(KeycapCases))]
    public void SlotAllowsExactlyItsWidth(string slot)
    {
        var expected = KeycapCases.CatalogCases().Where(row => (string)row[2] == (slot == "ACT10_ACT11" ? "double" : "single"));
        Assert.Equal(expected.Select(row => (string)row[0]).Order(), CodexKeycapCatalog.ForSlot(slot).Select(c => c.Id).Order());
    }

    [Theory, MemberData(nameof(KeycapCases.CommandCases), MemberType = typeof(KeycapCases))]
    public void AvailabilityDistinguishesThreadDraftAndUnknown(string command)
    {
        Assert.Null(CodexActionCatalog.SoftwareUnavailableReason(command, hasThread: true));
        var expected = command switch
        {
            "forkThread" or "toggleReviewTab" or "approval.approve" or "approval.decline" or
                "turn.cancel" or "composer.toggleFastMode" or "composer.togglePlanMode" or
                "composer.increaseReasoningEffort" or "composer.decreaseReasoningEffort" => "action.thread-required",
            _ => null,
        };
        Assert.Equal(expected, CodexActionCatalog.SoftwareUnavailableReason(command, hasThread: false));
        Assert.Equal(command is "composer.toggleFastMode" or "composer.togglePlanMode" or
            "composer.increaseReasoningEffort" or "composer.decreaseReasoningEffort" ? null : expected,
            CodexActionCatalog.SoftwareUnavailableReason(command, hasThread: false, hasDraft: true));
        Assert.Equal(CodexActionCatalog.SoftwareUnavailableReason(command, hasThread: false, hasDraft: true),
            CodexActionCatalog.SoftwareUnavailableReason(command, hasThread: false, hasComposer: true));
    }

    [Theory]
    [InlineData("unassigned", "action.unassigned")]
    [InlineData("dictation.pushToTalk", "action.unsupported")]
    [InlineData("not-a-command", "action.unsupported")]
    [InlineData("", "action.unsupported")]
    public void UnsupportedAndUnassignedAreNotReportedAsAvailable(string command, string reason) =>
        Assert.Equal(reason, CodexActionCatalog.SoftwareUnavailableReason(command, true, true));

    [Theory]
    [InlineData("APPR", null, null, "approval.approve")]
    [InlineData("APPR", "newTask", null, "newTask")]
    [InlineData("APPR", "newTask", "turn.cancel", "turn.cancel")]
    [InlineData("EMPT1", null, "composer.submit", "composer.submit")]
    [InlineData("missing-keycap", null, null, "unknown")]
    public void ExplicitBindingWinsOverLegacyAndIconDefault(string icon, string? legacy, string? explicitAction, string expected)
    {
        var binding = new CodexMicroSlotBinding(icon, legacy, explicitAction is null ? null : new("command", explicitAction));
        Assert.Equal(expected, binding.ResolvedAction);
    }
}
