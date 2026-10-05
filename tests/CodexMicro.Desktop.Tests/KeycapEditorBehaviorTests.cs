using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using System.Reflection;
using CodexMicro.Desktop.Services;
using Xunit;

namespace CodexMicro.Desktop.Tests;

[Collection(WpfUiCollection.Name), Trait("Scope", "Keycaps"), Trait("Layer", "L1")]
public sealed class KeycapEditorBehaviorTests
{
    [Theory, Trait("Case", "E01"), Trait("Risk", "P0")]
    [InlineData("MIC1", "NEW", "newTask")]
    [InlineData("EMPT1", "NEW", "newTask")]
    [InlineData("MIC1", "SKETCH", "composer.sketch")]
    [InlineData("EMPT1", "FAST", "composer.toggleFastMode")]
    public Task PlaceholderSelectionOffersTheNewDefault(string initial, string icon, string command) => KeycapUiThread.Run(async () =>
    {
        using var fixture = new EditorFixture("ACT10", new(initial, null));
        Assert.False(fixture.Editor.SaveButton.IsEnabled);
        fixture.SelectIcon(icon);
        await Dispatcher.Yield(DispatcherPriority.DataBind);
        Assert.Equal(command, Choice(fixture.Editor.ActionCombo.SelectedItem, "Id"));
        Assert.True(fixture.Editor.SaveButton.IsEnabled);
        Assert.False(File.Exists(fixture.Files.Config));
    });

    [Theory, Trait("Case", "E02"), Trait("Risk", "P0")]
    [InlineData("default")]
    [InlineData("legacy")]
    [InlineData("command")]
    public Task ChoosingAKeycapSelectsItsCommandForEveryPreviousBindingKind(string kind) => KeycapUiThread.Run(async () =>
    {
        var binding = kind switch
        {
            "legacy" => new CodexMicroSlotBinding("APPR", "turn.cancel"),
            "command" => new("APPR", null, new("command", "turn.cancel")),
            _ => new("APPR", null),
        };
        using var fixture = new EditorFixture("ACT07", binding);
        var choice = fixture.Editor.ActionCombo.SelectedItem;
        // A catalog command has one dropdown entry, including when it is inherited
        // from the keycap. The initial resolved action must still be preserved.
        Assert.Equal("command", Choice(choice, "Kind"));
        Assert.Equal(kind == "default" ? "approval.approve" : "turn.cancel", Choice(choice, "Id"));
        fixture.SelectIcon("NEW");
        Assert.Equal("newTask", Choice(fixture.Editor.ActionCombo.SelectedItem, "Id"));
        fixture.SelectIcon("SKETCH");
        await Dispatcher.Yield(DispatcherPriority.DataBind);
        Assert.Equal("composer.sketch", Choice(fixture.Editor.ActionCombo.SelectedItem, "Id"));
        Assert.True(fixture.Editor.SaveButton.IsEnabled);
    });

    [Fact, Trait("Case", "E03"), Trait("Risk", "P0")]
    public Task ExplicitActionSurvivesLanguageChangesUntilAnotherKeycapIsChosen() => KeycapUiThread.Run(async () =>
    {
        using var fixture = new EditorFixture("ACT10", new("MIC1", null));
        fixture.SelectIcon("NEW");
        fixture.SelectAction("composer.submit");
        fixture.Localization.SetLanguage(MicroLanguage.ZhCn);
        Assert.Equal("composer.submit", Choice(fixture.Editor.ActionCombo.SelectedItem, "Id"));
        fixture.SelectIcon("FAST");
        Assert.Equal("composer.toggleFastMode", Choice(fixture.Editor.ActionCombo.SelectedItem, "Id"));
        fixture.SelectIcon("SKETCH");
        await Dispatcher.Yield(DispatcherPriority.DataBind);
        Assert.Equal("composer.sketch", Choice(fixture.Editor.ActionCombo.SelectedItem, "Id"));
        Assert.True(fixture.Editor.SaveButton.IsEnabled);
    });

    [Theory, Trait("Case", "E04"), Trait("Risk", "P0")]
    [InlineData(false)]
    [InlineData(true)]
    public Task LateSkillsCannotReplaceTheUsersCommandOrSavedSkillIdentity(bool chooseCommand) => KeycapUiThread.Run(async () =>
    {
        var response = new TaskCompletionSource<IReadOnlyList<CodexSkillDefinition>>();
        var reads = 0;
        using var fixture = new EditorFixture("ACT09", new("APPS", null, new("skill", "review", "C:/fixture/original/SKILL.md")),
            _ => { reads++; return response.Task; });
        Assert.Equal(0, reads);
        fixture.CompleteRenderLifecycle();
        Assert.Equal(1, reads);
        if (chooseCommand) fixture.SelectAction("newTask");
        response.SetResult([new("review", "C:/fixture/different/SKILL.md")]);
        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
        Assert.Equal(chooseCommand ? "newTask" : "review", Choice(fixture.Editor.ActionCombo.SelectedItem, "Id"));
        Assert.Equal(chooseCommand ? null : "C:/fixture/original/SKILL.md", Choice(fixture.Editor.ActionCombo.SelectedItem, "Path"));
    });

    [Fact, Trait("Case", "E08"), Trait("Risk", "P0")]
    public Task ClosingDuringSkillLoadCancelsAndCannotSave() => KeycapUiThread.Run(async () =>
    {
        var response = new TaskCompletionSource<IReadOnlyList<CodexSkillDefinition>>();
        CancellationToken observed = default;
        using var fixture = new EditorFixture("ACT09", new("SPLIT", null), token => { observed = token; return response.Task; });
        fixture.CompleteRenderLifecycle();
        fixture.SelectAction("newTask");
        fixture.Editor.CancelButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.True(observed.IsCancellationRequested);
        response.SetResult([new("late", "C:/fixture/late/SKILL.md")]);
        await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
        Assert.False(File.Exists(fixture.Files.Config));
        Assert.False(File.Exists(fixture.Files.Profile));
    });

    [Theory, MemberData(nameof(KeycapCases.CommandCases), MemberType = typeof(KeycapCases)), Trait("Case", "E05")]
    public Task EverySupportedCommandCanBeSelectedOnAnUnsupportedPicture(string command) => KeycapUiThread.Run(async () =>
    {
        using var fixture = new EditorFixture("ACT10", new("MIC1", null));
        fixture.SelectAction(command);
        await Dispatcher.Yield(DispatcherPriority.DataBind);
        Assert.Equal("MIC1", ((CodexKeycapDefinition)fixture.Editor.KeycapList.SelectedItem).Id);
        Assert.True(fixture.Editor.SaveButton.IsEnabled);
        Assert.Empty(fixture.Editor.EditorStatusText.Text);
    });

    [Theory, Trait("Case", "E05"), Trait("Risk", "P0")]
    [InlineData("dictation.pushToTalk")]
    [InlineData("missing-command")]
    public Task UnsupportedActionCannotSaveEvenWithASupportedPicture(string command) => KeycapUiThread.Run(async () =>
    {
        using var fixture = new EditorFixture("ACT07", new("NEW", null, new("command", command)));
        await Dispatcher.Yield(DispatcherPriority.DataBind);
        Assert.False(fixture.Editor.SaveButton.IsEnabled);
        // Also exercise the handler's defense against a stale/already queued event.
        fixture.Editor.SaveButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.False(File.Exists(fixture.Files.Config));
        Assert.False(File.Exists(fixture.Files.Profile));
        Assert.NotEmpty(fixture.Editor.EditorStatusText.Text);
    });

    [Theory, MemberData(nameof(KeycapCases.SlotCases), MemberType = typeof(KeycapCases)), Trait("Case", "E06")]
    public Task EverySlotUsesTheCorrectEditorAndWidth(string slot) => KeycapUiThread.Run(async () =>
    {
        using var fixture = new EditorFixture(slot, new(slot == "ACT10_ACT11" ? "MIC" : "EMPT1", null));
        Assert.Equal(slot, fixture.Editor.SlotId);
        Assert.Equal(slot, fixture.Editor.EditorSubtitleText.Text);
        var items = fixture.Editor.KeycapList.Items.Cast<CodexKeycapDefinition>().ToArray();
        Assert.Equal(slot == "ACT10_ACT11" ? 2 : 38, items.Length);
        Assert.All(items, item => Assert.Equal(slot == "ACT10_ACT11" ? "double" : "single", item.Size));
        fixture.SelectAction("newTask");
        await Dispatcher.Yield(DispatcherPriority.DataBind);
        Assert.True(fixture.Editor.SaveButton.IsEnabled);
    });

    [Fact, Trait("Case", "E07")]
    public Task SearchKeepsTheActionAndClearingItRestoresTheCatalog() => KeycapUiThread.Run(async () =>
    {
        using var fixture = new EditorFixture("ACT07", new("APPR", null));
        fixture.SelectAction("turn.cancel");
        fixture.Editor.SearchBox.Text = "SKETCH";
        Assert.Equal("turn.cancel", Choice(fixture.Editor.ActionCombo.SelectedItem, "Id"));
        Assert.Equal("SKETCH", Assert.Single(fixture.Editor.KeycapList.Items.Cast<CodexKeycapDefinition>()).Id);
        fixture.SelectIcon("SKETCH");
        fixture.Editor.SearchBox.Text = "";
        await Dispatcher.Yield(DispatcherPriority.DataBind);
        Assert.Equal(38, fixture.Editor.KeycapList.Items.Count);
        Assert.Equal("composer.sketch", Choice(fixture.Editor.ActionCombo.SelectedItem, "Id"));
    });

    [Fact, Trait("Case", "S04"), Trait("Risk", "P0")]
    public Task FailedConfigWriteKeepsBothBindingsAndTheEditableChoice() => KeycapUiThread.Run(async () =>
    {
        using var fixture = new EditorFixture("ACT07", new("APPR", null));
        const string original = "[desktop.codex-micro-layout.slots.ACT07]\nkeycapId = \"APPR\"\n";
        await File.WriteAllTextAsync(fixture.Files.Config, original);
        fixture.SelectIcon("NEW");
        fixture.SelectAction("newTask");
        using (var locked = new FileStream(fixture.Files.Config, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            fixture.Editor.SaveButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.Equal(original, await File.ReadAllTextAsync(fixture.Files.Config));
        Assert.False(File.Exists(fixture.Files.Profile));
        Assert.Equal("newTask", Choice(fixture.Editor.ActionCombo.SelectedItem, "Id"));
        Assert.Null(fixture.Editor.DialogResult);
        Assert.NotEmpty(fixture.Editor.EditorStatusText.Text);
    });

    [Fact, Trait("Case", "S05"), Trait("Risk", "P0")]
    public Task FailedIconWriteMustNotSilentlyCommitTheNewAction() => KeycapUiThread.Run(async () =>
    {
        using var fixture = new EditorFixture("ACT07", new("APPR", null));
        const string original = "[desktop.codex-micro-layout.slots.ACT07]\nkeycapId = \"APPR\"\n";
        await File.WriteAllTextAsync(fixture.Files.Config, original);
        Directory.CreateDirectory(fixture.Files.Profile); // Destination cannot be replaced by a file.
        fixture.SelectIcon("NEW");
        fixture.SelectAction("newTask");
        fixture.Editor.SaveButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.False(fixture.Profile.LastSaveSucceeded);
        Assert.NotEmpty(fixture.Editor.EditorStatusText.Text);
        Assert.Null(fixture.Editor.DialogResult);
        Assert.Equal(original, await File.ReadAllTextAsync(fixture.Files.Config));
        Assert.Equal("APPR", fixture.Profile.ResolveKeycapIcon("ACT07", "APPR"));
    });

    internal static string? Choice(object item, string property) =>
        (string?)item.GetType().GetProperty(property)!.GetValue(item);

    private sealed class EditorFixture : IDisposable
    {
        internal KeycapTestFiles Files { get; } = new();
        internal MicroLocalization Localization { get; } = new(MicroLanguage.EnUs);
        internal MicroProfileSettings Profile { get; }
        internal CodexMicroLayoutObserver Observer { get; }
        internal KeycapEditorWindow Editor { get; }
        internal EditorFixture(string slot, CodexMicroSlotBinding binding,
            Func<CancellationToken, Task<IReadOnlyList<CodexSkillDefinition>>>? skills = null)
        {
            Profile = new(Files.Profile, Files.Models);
            Observer = new(Files.Config);
            try
            {
                Editor = new(slot, binding, Localization, new(Files.Config), Observer,
                    skills ?? (_ => Task.FromResult<IReadOnlyList<CodexSkillDefinition>>([])), Profile);
            }
            catch
            {
                Observer.Dispose();
                Files.Dispose();
                throw;
            }
        }
        internal void SelectIcon(string id) => Editor.KeycapList.SelectedItem =
            Editor.KeycapList.Items.Cast<CodexKeycapDefinition>().Single(item => item.Id == id);
        // WPF's compiled XAML requires the concrete window type. Raise the protected
        // lifecycle event on that object; do not change private product state or open an HWND.
        internal void CompleteRenderLifecycle() => typeof(Window)
            .GetMethod("OnContentRendered", BindingFlags.Instance | BindingFlags.NonPublic)!
            .Invoke(Editor, [EventArgs.Empty]);
        internal void SelectAction(string id) => Editor.ActionCombo.SelectedItem =
            Editor.ActionCombo.Items.Cast<object>().Single(item => Choice(item, "Kind") == "command" && Choice(item, "Id") == id);
        public void Dispose() { Editor.Close(); Observer.Dispose(); Files.Dispose(); }
    }
}
