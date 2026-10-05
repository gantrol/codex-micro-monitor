using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Shapes;
using Path = System.IO.Path;
using CodexMicro.Codex;
using CodexMicro.Desktop;
using CodexMicro.Desktop.Controls;
using CodexMicro.Desktop.Services;

// Product WPF surface/transport + real Codex process. UIA is used only by this
// automated journey. No prompts, approvals, persistent Micro settings or test chats.
internal static class StartupFastVerification
{
    internal static async Task<int> RunAsync(MicroSurfaceWindow window, Stopwatch startup,
        long constructedMs, string reportPath)
    {
        var cases = new List<object>();
        var errors = new List<string>();
        var renderedMs = startup.ElapsedMilliseconds;
        var selected = new CodexSelectedThreadReader();
        await using var reader = new KeypadController();
        string? restoreThread = null;
        JsonNode? baseline = null;
        nint codexWindow = 0;
        bool? originalFast = null;
        string? pickerId = null;
        var restored = false;
        var navigationRestored = false;
        var acknowledgements = 0;
        var changes = DependencyPropertyDescriptor.FromProperty(Shape.FillProperty, typeof(Ellipse));
        EventHandler acknowledged = (_, _) => { if (ColorOf(window.ActivityLed) == "#FF74D9A0") acknowledgements++; };
        changes.AddValueChanged(window.ActivityLed, acknowledged);
        try
        {
            if (!CodexWindowActivator.TryActivate(null)) throw new Exception("Codex is not running");
            await Until(async () => (restoreThread = await selected.ReadAsync()) is not null, "existing chat selection");
            await Until(() => Task.FromResult(ColorOf(window.DriverLed) == "#FF9EBDFF" && ColorOf(window.RuntimeLed) == "#FF9EBDFF"), "startup synchronized");
            cases.Add(new { name = "startup", constructedMs, renderedMs, synchronizedMs = startup.ElapsedMilliseconds });
            Console.WriteLine($"Startup: constructed {constructedMs}, rendered {renderedMs}, synced {startup.ElapsedMilliseconds} ms");
            if (startup.Elapsed > TimeSpan.FromSeconds(5)) throw new Exception("Startup synchronization exceeded the five-second regression budget");
            baseline = await State();
            await reader.ExecuteAsync("new_keypad_thread", new());
            if (!CodexWindowActivator.TryActivate(null)) throw new Exception("Codex cannot be activated");
            codexWindow = CodexWindowActivator.CaptureForegroundWindow();
            var observer = new CodexDraftComposerModelSelector();
            await Until(async () =>
            {
                var draft = await observer.CaptureDraftContextAsync(null, CancellationToken.None);
                pickerId = draft?.ModelPickerId;
                return draft is not null && await selected.ReadAsync() is null;
            }, "new composer");
            using var layout = new CodexMicroLayoutObserver();
            await layout.ReloadNowAsync();
            var fastSlot = Enumerable.Range(6, 7).Select(i => $"ACT{i:00}")
                .Single(slot => layout.Current.GetSlot(slot).ResolvedAction == "composer.toggleFastMode");
            var fastButton = (Button)window.FindName("ActionKey" + fastSlot[3..]);
            var fastIcon = (KeycapIcon)window.FindName("ActionIcon" + fastButton.Name["ActionKey".Length..]);
            await Until(() => Task.FromResult(fastButton.IsEnabled), "draft Fast available",
                () => AutomationProperties.GetHelpText(fastButton));
            pickerId = (await observer.CaptureDraftContextAsync(null, CancellationToken.None))?.ModelPickerId
                ?? throw new Exception("Draft disappeared before Fast test");
            originalFast = await ReadFastAsync(codexWindow, pickerId!, openPicker: true);
            if (originalFast is null)
                await Until(async () => (originalFast = await ReadFastAsync(codexWindow, pickerId!, false)) is not null, "native speed observation");
            Console.WriteLine($"Draft Fast baseline: {originalFast}");
            if (originalFast is null) throw new Exception("Native speed could not be read");
            await ClosePickerAsync(codexWindow, pickerId!);
            foreach (var expected in new[] { !originalFast.Value, originalFast.Value })
            {
                var count = acknowledgements;
                var watch = Stopwatch.StartNew();
                fastButton.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
                await Until(() => Task.FromResult(fastIcon.IsFastActive == expected && acknowledgements == count + 1), "draft Fast = " + expected,
                    () => AutomationProperties.GetHelpText(window.ActivityLed));
                await ReadFastAsync(codexWindow, pickerId!, true);
                await Until(async () => await ReadFastAsync(codexWindow, pickerId!, false) == expected, "native Fast = " + expected);
                await ClosePickerAsync(codexWindow, pickerId!);
                cases.Add(new { name = "draft Fast round trip", expected, elapsedMs = watch.ElapsedMilliseconds });
                Console.WriteLine($"Draft Fast {expected}: {watch.ElapsedMilliseconds} ms");
            }
            var rapidCount = acknowledgements;
            fastButton.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            fastButton.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            await Until(() => Task.FromResult(acknowledgements == rapidCount + 2 && fastIcon.IsFastActive == originalFast),
                "two queued Fast clicks", () => AutomationProperties.GetHelpText(window.ActivityLed));
            await ReadFastAsync(codexWindow, pickerId!, true);
            await Until(async () => await ReadFastAsync(codexWindow, pickerId!, false) == originalFast, "queued Fast native readback");
            await ClosePickerAsync(codexWindow, pickerId!);
            cases.Add(new { name = "two queued Fast clicks restore original speed", acknowledgements = acknowledgements - rapidCount });
            restored = true;
            var after = await State();
            foreach (var key in new[] { "model", "effort", "serviceTier" })
                if (baseline[key]?.ToJsonString() != after[key]?.ToJsonString()) throw new Exception("Existing chat changed: " + key);
        }
        catch (Exception error) { errors.Add(error.ToString()); Console.WriteLine(error.Message); }
        finally
        {
            changes.RemoveValueChanged(window.ActivityLed, acknowledged);
            try { await window.CloseForApplicationExitAsync().WaitAsync(TimeSpan.FromSeconds(10)); }
            catch (Exception error) { errors.Add("Surface cleanup: " + error.Message); }
            try
            {
                if (pickerId is not null && originalFast is { } original)
                {
                    var current = await ReadFastAsync(codexWindow, pickerId, true);
                    if (current is null)
                        await Until(async () => (current = await ReadFastAsync(codexWindow, pickerId, false)) is not null, "cleanup native speed");
                    if (current != original)
                        await Task.Run(() => ((TogglePattern)FindSpeedToggle(codexWindow)!.GetCurrentPattern(TogglePattern.Pattern)).Toggle());
                    await Until(async () => await ReadFastAsync(codexWindow, pickerId, false) == original, "draft speed restoration");
                    restored = true;
                }
                if (pickerId is not null) await ClosePickerAsync(codexWindow, pickerId);
            }
            catch (Exception error) { errors.Add("Cleanup: " + error.Message); }
            if (restoreThread is not null)
            {
                try
                {
                    await reader.ExecuteAsync("open_keypad_thread", new() { ["thread_id"] = restoreThread });
                    await Until(async () => await selected.ReadAsync() == restoreThread, "original chat restoration");
                    navigationRestored = true;
                }
                catch (Exception error) { errors.Add("Navigation cleanup: " + error.Message); }
            }
        }
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(reportPath))!);
        await File.WriteAllTextAsync(reportPath, JsonSerializer.Serialize(new
        {
            timeUtc = DateTimeOffset.UtcNow, constructedMs, renderedMs, cases, errors, restored, navigationRestored,
            windowsVersion = Environment.OSVersion.VersionString,
            controlVersion = typeof(AgentController.Adapters.Codex.Windows.CodexUiController).Assembly
                .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
                .Cast<System.Reflection.AssemblyInformationalVersionAttribute>().Single().InformationalVersion,
            scope = "Real product WPF surface and Codex app; routed clicks and independent native speed readback; no OS pointer hit testing or packaged launcher",
        }, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine($"{(errors.Count == 0 ? "PASS" : "FAIL")}: {reportPath}");
        return errors.Count == 0 ? 0 : 1;

        Task<JsonNode> State() => reader.ExecuteAsync("get_keypad_state", new() { ["thread_id"] = restoreThread });
    }

    private static string? ColorOf(Ellipse led) => (led.Fill as SolidColorBrush)?.Color.ToString();

    private static async Task Until(Func<Task<bool>> condition, string stage, Func<string>? detail = null)
    {
        var watch = Stopwatch.StartNew();
        do
        {
            if (await condition().WaitAsync(TimeSpan.FromSeconds(10))) return;
            await Task.Delay(100); // Bounded read-only polling; actions are never retried.
        } while (watch.Elapsed < TimeSpan.FromSeconds(20));
        throw new Exception(stage + " timed out: " + detail?.Invoke());
    }

    private static readonly string[] SpeedLabels =
        ["Enable fast mode", "Enable standard mode", "启用快速模式", "启用标准模式", "啟用快速模式", "啟用標準模式"];

    private static AutomationElement? FindSpeedToggle(nint window) => AutomationElement.FromHandle(window)
        .FindAll(TreeScope.Descendants, new OrCondition(
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.CheckBox)))
        .Cast<AutomationElement>().SingleOrDefault(element => !element.Current.IsOffscreen && SpeedLabels.Contains(element.Current.Name));

    private static Task<bool?> ReadFastAsync(nint window, string pickerId, bool openPicker) => Task.Run(() =>
    {
        if (!CodexWindowActivator.IsForegroundWindow(window)) throw new Exception("Codex lost foreground during the test");
        var root = AutomationElement.FromHandle(window);
        var picker = root.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty, pickerId));
        if (picker is null) throw new Exception("Tested draft model picker disappeared");
        if (openPicker && picker.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out var expand) &&
            ((ExpandCollapsePattern)expand).Current.ExpandCollapseState == ExpandCollapseState.Collapsed)
            ((ExpandCollapsePattern)expand).Expand();
        var toggle = FindSpeedToggle(window);
        if (toggle is not null) return (bool?)(toggle.Current.Name is "Enable standard mode" or "启用标准模式" or "啟用標準模式");
        var name = picker.Current.Name;
        if (name.EndsWith("Fast", StringComparison.OrdinalIgnoreCase) || name.EndsWith("快速", StringComparison.Ordinal)) return true;
        if (name.EndsWith("Standard", StringComparison.OrdinalIgnoreCase) || name.EndsWith("标准", StringComparison.Ordinal)) return false;
        return null;
    });

    private static Task ClosePickerAsync(nint window, string pickerId) => Task.Run(() =>
    {
        if (!CodexWindowActivator.IsForegroundWindow(window)) return;
        var picker = AutomationElement.FromHandle(window).FindFirst(TreeScope.Descendants,
            new PropertyCondition(AutomationElement.AutomationIdProperty, pickerId));
        if (picker?.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out var pattern) == true &&
            ((ExpandCollapsePattern)pattern).Current.ExpandCollapseState == ExpandCollapseState.Expanded)
            ((ExpandCollapsePattern)pattern).Collapse();
    });
}
