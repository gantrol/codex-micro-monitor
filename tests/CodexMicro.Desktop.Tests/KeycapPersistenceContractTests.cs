using CodexMicro.Desktop.Services;
using Tomlyn;
using Tomlyn.Model;
using Xunit;

namespace CodexMicro.Desktop.Tests;

[Trait("Scope", "Keycaps"), Trait("Layer", "L3")]
public sealed class KeycapPersistenceContractTests
{
    [Theory, MemberData(nameof(KeycapCases.SlotCases), MemberType = typeof(KeycapCases)), Trait("Case", "S10")]
    public async Task EverySlotPersistsItsCommandAndIconWithoutChangingOtherSlots(string slot)
    {
        using var files = new KeycapTestFiles();
        await File.WriteAllTextAsync(files.Config, "model = \"fixture-model\"\n[features]\napps = true\n");
        var writer = new CodexMicroConfigWriter(files.Config);
        var profile = new MicroProfileSettings(files.Profile, files.Models);
        profile.SetKeypadName("Fixture keypad");
        var other = slot == "ACT07" ? "ACT08" : "ACT07";
        Assert.True(writer.SetSlot(other, "APPR", new("command", "approval.approve")));
        profile.SetKeycapIcon(other, "APPR");
        Assert.True(writer.SetSlot(slot, slot == "ACT10_ACT11" ? "MIC" : "EMPT1", new("command", "newTask")));
        profile.SetKeycapIcon(slot, slot == "ACT10_ACT11" ? "EMPT5" : "NEW");
        Assert.True(profile.LastSaveSucceeded);

        var model = Toml.ToModel(await File.ReadAllTextAsync(files.Config));
        Assert.Equal("fixture-model", model["model"]);
        Assert.Equal(true, Table(model, "features")["apps"]);
        Assert.Equal("newTask", Table(model, "desktop", "codex-micro-layout", "slots", slot, "action")["commandId"]);
        using var reloaded = new CodexMicroLayoutObserver(files.Config);
        await reloaded.ReloadNowAsync();
        var reopenedProfile = new MicroProfileSettings(files.Profile, files.Models);
        Assert.Equal("newTask", reloaded.Current.GetSlot(slot).ResolvedAction);
        Assert.Equal("approval.approve", reloaded.Current.GetSlot(other).ResolvedAction);
        Assert.Equal(slot == "ACT10_ACT11" ? "EMPT5" : "NEW", reopenedProfile.ResolveKeycapIcon(slot, "missing"));
        Assert.Equal("APPR", reopenedProfile.ResolveKeycapIcon(other, "missing"));
        Assert.Equal("Fixture keypad", reopenedProfile.Current.KeypadName);
    }

    [Theory, MemberData(nameof(KeycapCases.SlotCases), MemberType = typeof(KeycapCases)), Trait("Case", "S02")]
    public async Task SkillIdentitySurvivesAllSlotsAndIndependentParsing(string slot)
    {
        using var files = new KeycapTestFiles();
        const string name = "审查 \"quoted\" \\ skill";
        var skillPath = Path.Combine(files.Root, "中文 space", "SKILL.md");
        Assert.True(new CodexMicroConfigWriter(files.Config).SetSlot(slot,
            slot == "ACT10_ACT11" ? "EMPT5" : "APPS", new("skill", name, skillPath)));
        var text = await File.ReadAllTextAsync(files.Config);
        var action = Table(Toml.ToModel(text), "desktop", "codex-micro-layout", "slots", slot, "action");
        Assert.Equal("skill", action["type"]);
        Assert.Equal(name, action["skillName"]);
        Assert.Equal(skillPath, action["skillPath"]);
        using var observer = new CodexMicroLayoutObserver(files.Config);
        await observer.ReloadNowAsync();
        Assert.Equal(new CodexMicroActionBinding("skill", name, skillPath), observer.Current.GetSlot(slot).Action);
    }

    [Theory, Trait("Case", "S01"), Trait("Risk", "P0")]
    [InlineData("expanded")]
    [InlineData("slot-inline")]
    [InlineData("layout-inline")]
    public async Task EveryReadableTomlFormRemainsValidAfterChangingAnAction(string format)
    {
        using var files = new KeycapTestFiles();
        var source = format switch
        {
            "slot-inline" => "[desktop.codex-micro-layout.slots]\nACT07 = { keycapId = \"APPR\" }\n",
            "layout-inline" => "[desktop]\ncodex-micro-layout = { slots = { ACT07 = { keycapId = \"APPR\" } } }\n",
            _ => "[desktop.codex-micro-layout.slots.ACT07]\nkeycapId = \"APPR\"\n",
        };
        Assert.Equal("APPR", Table(Toml.ToModel(source), "desktop", "codex-micro-layout", "slots", "ACT07")["keycapId"]);
        await File.WriteAllTextAsync(files.Config, source);
        Assert.True(new CodexMicroConfigWriter(files.Config).SetSlot("ACT07", "NEW", new("command", "newTask")));
        var text = await File.ReadAllTextAsync(files.Config);
        // An independent standard parser must accept the result before the app's observer is trusted.
        var saved = Table(Toml.ToModel(text), "desktop", "codex-micro-layout", "slots", "ACT07");
        Assert.Equal("NEW", saved["keycapId"]);
        Assert.Equal("newTask", Table(saved, "action")["commandId"]);
        Assert.Equal("newTask", CodexMicroLayoutObserver.Parse(text, files.Config).GetSlot("ACT07").ResolvedAction);
    }

    [Theory, Trait("Case", "S02")]
    [InlineData("\n")]
    [InlineData("\r\n")]
    public async Task CommentsLineEndingsAndUnrelatedSettingsSurviveReplacement(string newline)
    {
        using var files = new KeycapTestFiles();
        var source = string.Join(newline, new[]
        {
            "# user comment", "model = \"fixture\"", "[desktop.codex-micro-layout.slots.ACT07]",
            "keycapId = \"APPR\"", "commandId = \"turn.cancel\"", "# retained comment",
            "[features]", "apps = true", "",
        });
        await File.WriteAllTextAsync(files.Config, source);
        Assert.True(new CodexMicroConfigWriter(files.Config).SetSlot("ACT07", "NEW", new("command", "newTask")));
        var text = await File.ReadAllTextAsync(files.Config);
        var model = Toml.ToModel(text);
        Assert.Equal("fixture", model["model"]);
        Assert.Equal(true, Table(model, "features")["apps"]);
        Assert.Contains("# user comment", text);
        Assert.Contains("# retained comment", text);
        Assert.DoesNotContain("commandId = \"turn.cancel\"", text);
        if (newline == "\r\n") Assert.DoesNotContain("\n", text.Replace("\r\n", ""));
        else Assert.DoesNotContain("\r", text);
    }

    [Fact, Trait("Case", "S04"), Trait("Risk", "P0")]
    public async Task FailedReplacementLeavesOriginalBytesIntact()
    {
        using var files = new KeycapTestFiles();
        const string original = "model = \"keep\"\n";
        await File.WriteAllTextAsync(files.Config, original);
        using (var locked = new FileStream(files.Config, FileMode.Open, FileAccess.Read, FileShare.Read))
            Assert.False(new CodexMicroConfigWriter(files.Config).SetSlot("ACT07", "NEW", new("command", "newTask")));
        Assert.Equal(original, await File.ReadAllTextAsync(files.Config));
    }

    [Fact, Trait("Case", "S07"), Trait("Risk", "P0")]
    public async Task SequentialWritersMergeDifferentSlotsAndSplitModePreservesAllThreeBindings()
    {
        using var files = new KeycapTestFiles();
        var first = new CodexMicroConfigWriter(files.Config);
        var second = new CodexMicroConfigWriter(files.Config);
        Assert.True(first.SetSlot("ACT10", "NEW", new("command", "newTask")));
        Assert.True(second.SetSlot("ACT11", "CODEX", new("command", "composer.submit")));
        Assert.True(first.SetSlot("ACT10_ACT11", "EMPT5", new("command", "turn.cancel")));
        foreach (var split in new[] { true, false, true })
        {
            Assert.True(await second.SetSeparateMicrophoneKeysAsync(split));
            using var observer = new CodexMicroLayoutObserver(files.Config);
            await observer.ReloadNowAsync();
            Assert.Equal(split, observer.Current.SeparateMicrophoneKeys);
            Assert.Equal("newTask", observer.Current.GetSlot("ACT10").ResolvedAction);
            Assert.Equal("composer.submit", observer.Current.GetSlot("ACT11").ResolvedAction);
            Assert.Equal("turn.cancel", observer.Current.GetSlot("ACT10_ACT11").ResolvedAction);
            _ = Toml.ToModel(await File.ReadAllTextAsync(files.Config));
        }
    }

    [Fact, Trait("Case", "S08"), Trait("Risk", "P0")]
    public async Task MalformedExistingConfigMustNotBeReportedAsSuccessfullySaved()
    {
        using var files = new KeycapTestFiles();
        const string malformed = "model = \"unterminated\n";
        await File.WriteAllTextAsync(files.Config, malformed);
        Assert.False(new CodexMicroConfigWriter(files.Config).SetSlot("ACT07", "NEW", new("command", "newTask")));
        Assert.Equal(malformed, await File.ReadAllTextAsync(files.Config));
    }

    [Fact, Trait("Case", "S09")]
    public async Task ResetAndCanceledResetHaveDistinctDurableOutcomes()
    {
        using var files = new KeycapTestFiles();
        await File.WriteAllTextAsync(files.Config, "model = \"keep\"\n");
        var writer = new CodexMicroConfigWriter(files.Config);
        Assert.True(writer.SetSlot("ACT07", "NEW", new("command", "newTask")));
        var before = await File.ReadAllTextAsync(files.Config);
        using var canceled = new CancellationTokenSource();
        canceled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => writer.ResetLayoutAsync(canceled.Token));
        Assert.Equal(before, await File.ReadAllTextAsync(files.Config));
        Assert.True(await writer.ResetLayoutAsync(CancellationToken.None));
        var reset = Toml.ToModel(await File.ReadAllTextAsync(files.Config));
        Assert.Equal("keep", reset["model"]);
        using var observer = new CodexMicroLayoutObserver(files.Config);
        await observer.ReloadNowAsync();
        Assert.Equal("approval.approve", observer.Current.GetSlot("ACT07").ResolvedAction);
        Assert.False(observer.Current.SeparateMicrophoneKeys);
        Assert.Empty(Directory.GetFiles(files.Root, "*.tmp"));
    }

    [Fact, Trait("Case", "S10")]
    public async Task ObserverKeepsLastCompleteStateDuringALockedReadAndThenLoadsTheNewState()
    {
        using var files = new KeycapTestFiles();
        var writer = new CodexMicroConfigWriter(files.Config);
        Assert.True(writer.SetSlot("ACT07", "NEW", new("command", "newTask")));
        using var observer = new CodexMicroLayoutObserver(files.Config);
        await observer.ReloadNowAsync();
        using (var locked = new FileStream(files.Config, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            await observer.ReloadNowAsync();
            Assert.Equal("newTask", observer.Current.GetSlot("ACT07").ResolvedAction);
        }
        Assert.True(writer.SetSlot("ACT07", "CODEX", new("command", "composer.submit")));
        await observer.ReloadNowAsync();
        Assert.Equal("composer.submit", observer.Current.GetSlot("ACT07").ResolvedAction);
    }

    [Theory]
    [InlineData("slot")]
    [InlineData("icon")]
    [InlineData("binding-type")]
    [InlineData("skill-path")]
    public void InvalidBindingInputCannotCreateAConfiguration(string invalid)
    {
        using var files = new KeycapTestFiles();
        var writer = new CodexMicroConfigWriter(files.Config);
        Assert.Throws<ArgumentOutOfRangeException>(() => writer.SetSlot(
            invalid == "slot" ? "ACT99" : "ACT07", invalid == "icon" ? "NOT-AN-ICON" : "NEW",
            invalid switch
            {
                "binding-type" => new("unknown", "newTask"),
                "skill-path" => new("skill", "review", ""),
                _ => new CodexMicroActionBinding("command", "newTask"),
            }));
        Assert.False(File.Exists(files.Config));
    }

    [Fact, Trait("Case", "S03")]
    public async Task DefaultBindingCanReplaceAnExplicitActionWithoutLeavingLegacyFields()
    {
        using var files = new KeycapTestFiles();
        await File.WriteAllTextAsync(files.Config, """
            [desktop.codex-micro-layout.slots.ACT07]
            keycapId = "APPR"
            commandId = "turn.cancel"
            action = { type = "command", commandId = "newTask" }
            """);
        Assert.True(new CodexMicroConfigWriter(files.Config).SetSlot("ACT07", "SKETCH", null));
        var text = await File.ReadAllTextAsync(files.Config);
        var slot = Table(Toml.ToModel(text), "desktop", "codex-micro-layout", "slots", "ACT07");
        Assert.False(slot.ContainsKey("commandId"));
        Assert.False(slot.ContainsKey("action"));
        Assert.Equal("composer.sketch", CodexMicroLayoutObserver.Parse(text, files.Config).GetSlot("ACT07").ResolvedAction);
    }

    private static TomlTable Table(TomlTable table, params string[] path)
    {
        foreach (var key in path) table = Assert.IsType<TomlTable>(table[key]);
        return table;
    }
}
