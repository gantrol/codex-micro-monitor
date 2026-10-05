using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Automation;
using CodexMicro.Desktop.Services;

// OS mouse input into the installed/running WPF process, followed by independent
// readback from Codex's accessibility providers. Never submits composer content.
internal static class RunningControlsE2e
{
    internal static async Task<int> ProbeAsync()
    {
        CodexWindowActivator.TryActivate(null);
        CodexWindowActivator.TryFindMainWindow(out var hwnd, out _);
        var root = AutomationElement.FromHandle(hwnd);
        var originalTitles = CodexSelectedThreadReader.ReadSelectedTitles(hwnd);
        AutomationElement Button(string name) => root.FindFirst(TreeScope.Descendants, new AndCondition(
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
            new PropertyCondition(AutomationElement.IsOffscreenProperty, false),
            new PropertyCondition(AutomationElement.NameProperty, name)));
        void Invoke(string name)
        {
            var button = Button(name);
            if (button.TryGetCurrentPattern(InvokePattern.Pattern, out var invoke)) ((InvokePattern)invoke).Invoke();
            else ((TogglePattern)button.GetCurrentPattern(TogglePattern.Pattern)).Toggle();
        }
        try
        {
            Process.Start(new ProcessStartInfo("codex://settings") { UseShellExecute = true });
            await Until(() => Button("Keyboard shortcuts") is not null, "shortcut settings navigation");
            Invoke("Keyboard shortcuts");
            await Until(() => Button("Search by keystrokes") is not null, "shortcut capture available");
            var search = root.FindFirst(TreeScope.Descendants, new AndCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit),
                new PropertyCondition(AutomationElement.NameProperty, "Search keyboard shortcuts")));
            ((ValuePattern)search.GetCurrentPattern(ValuePattern.Pattern)).SetValue("Decrease reasoning effort");
            await Task.Delay(400);
            Invoke("Change shortcut for Decrease reasoning effort");
            await Task.Delay(400);
            var cache = new CacheRequest { TreeScope = TreeScope.Element };
            cache.Add(AutomationElement.NameProperty);
            AutomationElementCollection elements;
            using (cache.Activate()) elements = root.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.IsOffscreenProperty, false));
            Console.WriteLine(string.Join(" | ", elements.Cast<AutomationElement>().Select(e => e.Cached.Name).Where(n => n.Length > 0 && n.Length < 120)));
            AgentController.Adapters.Codex.Windows.NativeUi.Shortcut(() => {}, 0, 0x1B);
        }
        finally
        {
            Process.Start(new ProcessStartInfo("codex://threads/01a1077d-0493-7cc0-a048-9f6ca4cf707e") { UseShellExecute = true });
        }
        return 0;
    }
    private static readonly string[] SpeedLabels =
        ["Enable fast mode", "Enable standard mode", "启用快速模式", "启用标准模式", "啟用快速模式", "啟用標準模式"];

    internal static async Task<int> RunAsync(string reportPath)
    {
        var cases = new List<object>();
        var errors = new List<string>();
        var restored = false;
        string? originalModel = null, originalSpeed = null, pickerId = null;
        string[]? selectedTitles = null;
        AutomationElement? root = null;
        GetPhysicalCursorPos(out var pointer);
        using var micro = SingleMicro();
        var binary = micro.MainModule!.FileName;
        try
        {
            if (!CodexWindowActivator.TryActivate(null) || !CodexWindowActivator.TryFindMainWindow(out var hwnd, out _))
                throw new Exception("Codex main window unavailable");
            root = AutomationElement.FromHandle(hwnd);
            selectedTitles = CodexSelectedThreadReader.ReadSelectedTitles(hwnd).ToArray();
            var picker = Picker(root);
            pickerId = picker.Current.AutomationId;
            originalSpeed = await ReadSpeedAsync(root, pickerId);
            originalModel = Picker(root, pickerId).Current.Name;
            Console.WriteLine($"Baseline: {originalModel}; speed={originalSpeed}; Micro PID={micro.Id}");
            void GuardTarget()
            {
                if (!CodexWindowActivator.IsForegroundWindow(hwnd) || Picker(root, pickerId).Current.AutomationId != pickerId)
                    throw new Exception("Codex target changed; no further test input");
            }

            var watch = Stopwatch.StartNew();
            // Fast is a native cycle (some accounts have more than two speeds).
            var previous = originalSpeed;
            for (var i = 0; i < 3; i++)
            {
                watch.Restart();
                await ClickMicroAsync(micro.Id, "ActionKey09", GuardTarget);
                await Until(() => IsClosed(root, pickerId), "Fast closed its model menu");
                var actual = await ReadSpeedAsync(root, pickerId);
                if (actual == previous) throw new Exception($"Fast click {i + 1} did not change native speed ({actual})");
                cases.Add(new { name = "Fast", before = previous, after = actual, menuClosed = true, elapsedMs = watch.ElapsedMilliseconds });
                previous = actual;
                if (actual == originalSpeed) break;
            }
            if (previous != originalSpeed) throw new Exception("Fast did not return to the original speed within three clicks");
            if (Picker(root, pickerId).Current.Name != originalModel) throw new Exception("Fast changed the model or effort");
            // Test down first to allow an initial maximum effort, then restore via MIND+.
            watch.Restart();
            await ClickMicroAsync(micro.Id, "ActionKey08", GuardTarget);
            await Until(() => Picker(root, pickerId).Current.Name != originalModel, "MIND− changed native effort");
            var lower = Picker(root, pickerId).Current.Name;
            cases.Add(new { name = "MIND−", before = originalModel, after = lower, elapsedMs = watch.ElapsedMilliseconds });
            watch.Restart();
            await ClickMicroAsync(micro.Id, "ActionKey07", GuardTarget);
            await Until(() => Picker(root, pickerId).Current.Name == originalModel, "MIND+ restored native effort");
            cases.Add(new { name = "MIND+", before = lower, after = originalModel, elapsedMs = watch.ElapsedMilliseconds });

            restored = true;
        }
        catch (Exception error) { errors.Add(error.ToString()); Console.WriteLine(error.Message); }
        finally
        {
            try
            {
                if (root is not null && pickerId is not null && originalModel is not null && originalSpeed is not null)
                {
                    void GuardTarget()
                    {
                        if (!CodexWindowActivator.IsForeground() || Picker(root, pickerId).Current.AutomationId != pickerId)
                            throw new Exception("Codex target changed; restoration stopped");
                    }
                    // Restoration uses the same visible buttons, and never retries the tested click itself.
                    var current = Picker(root, pickerId).Current.Name;
                    for (var i = 0; current != originalModel && i < 6; i++)
                    {
                        await ClickMicroAsync(micro.Id, "ActionKey07", GuardTarget);
                        var next = Picker(root, pickerId).Current.Name;
                        if (next == current) break;
                        current = next;
                    }
                    var speed = await ReadSpeedAsync(root, pickerId);
                    for (var i = 0; speed != originalSpeed && i < 3; i++)
                    {
                        await ClickMicroAsync(micro.Id, "ActionKey09", GuardTarget);
                        speed = await ReadSpeedAsync(root, pickerId);
                    }
                    restored = current == originalModel && speed == originalSpeed;
                    if (!restored) errors.Add("Original native model/effort/speed was not restored");
                    if (CodexWindowActivator.TryFindMainWindow(out var hwnd, out _) &&
                        !CodexSelectedThreadReader.ReadSelectedTitles(hwnd).SequenceEqual(selectedTitles ?? []))
                        errors.Add("Selected chat changed during E2E");
                }
            }
            catch (Exception error) { errors.Add("Restoration: " + error); }
            SetPhysicalCursorPos(pointer.X, pointer.Y);
        }
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(reportPath))!);
        await File.WriteAllTextAsync(reportPath, JsonSerializer.Serialize(new
        {
            timeUtc = DateTimeOffset.UtcNow, binary, microPid = micro.Id,
            cases, errors, restored, originalModel, originalSpeed,
            scope = "External running Micro; OS mouse clicks; independent Codex UIA readback; no chat submission",
        }, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine($"{(errors.Count == 0 ? "PASS" : "FAIL")}: {reportPath}");
        return errors.Count == 0 ? 0 : 1;
    }

    private static Process SingleMicro()
    {
        var processes = Process.GetProcessesByName("CodexMicro");
        if (processes.Length == 1) return processes[0];
        foreach (var process in processes) process.Dispose();
        throw new Exception($"Expected exactly one Micro process, found {processes.Length}");
    }

    private static AutomationElement Picker(AutomationElement root, string? id = null) =>
        root.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button))
            .Cast<AutomationElement>().Single(element => !element.Current.IsOffscreen &&
                (id is not null ? element.Current.AutomationId == id :
                    (element.Current.Name.StartsWith("GPT", StringComparison.Ordinal) || element.Current.Name == "Select effort") &&
                    element.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out _)));

    private static bool IsClosed(AutomationElement root, string id) =>
        ((ExpandCollapsePattern)Picker(root, id).GetCurrentPattern(ExpandCollapsePattern.Pattern)).Current.ExpandCollapseState == ExpandCollapseState.Collapsed;

    private static async Task<string> ReadSpeedAsync(AutomationElement root, string id)
    {
        var pattern = (ExpandCollapsePattern)Picker(root, id).GetCurrentPattern(ExpandCollapsePattern.Pattern);
        if (pattern.Current.ExpandCollapseState == ExpandCollapseState.Collapsed) pattern.Expand();
        try
        {
            string? speed = null;
            await Until(() =>
            {
                var control = root.FindAll(TreeScope.Descendants, new AndCondition(
                    new PropertyCondition(AutomationElement.IsOffscreenProperty, false),
                    new OrCondition(SpeedLabels.Select(name => (Condition)new PropertyCondition(AutomationElement.NameProperty, name)).ToArray())))
                    .Cast<AutomationElement>().SingleOrDefault();
                speed = control?.Current.Name switch
                {
                    "Enable standard mode" or "启用标准模式" or "啟用標準模式" => "fast",
                    "Enable fast mode" or "启用快速模式" or "啟用快速模式" => "standard",
                    _ => null,
                };
                return speed is not null;
            }, "native speed readback");
            return speed!;
        }
        finally
        {
            pattern = (ExpandCollapsePattern)Picker(root, id).GetCurrentPattern(ExpandCollapsePattern.Pattern);
            if (pattern.Current.ExpandCollapseState == ExpandCollapseState.Expanded)
            {
                if (!CodexWindowActivator.IsForeground()) throw new Exception("Codex lost foreground during menu cleanup");
                var inputs = new[] { new Input { Type = 1, Keyboard = new KeyboardInput { Key = 0x1B } },
                    new Input { Type = 1, Keyboard = new KeyboardInput { Key = 0x1B, Flags = 2 } } };
                if (SendInput(2, inputs, Marshal.SizeOf<Input>()) != 2) throw new Exception("Menu Escape failed");
            }
            await Until(() => IsClosed(root, id), "test reader closed model menu");
        }
    }

    private static async Task ClickMicroAsync(int pid, string id, Action guardTarget)
    {
        var roots = AutomationElement.RootElement.FindAll(TreeScope.Children,
            new PropertyCondition(AutomationElement.ProcessIdProperty, pid)).Cast<AutomationElement>();
        var button = roots.Select(root => root.FindFirst(TreeScope.Descendants,
            new PropertyCondition(AutomationElement.AutomationIdProperty, id))).Single(element => element is not null);
        if (!button.Current.IsEnabled) throw new Exception($"{id} disabled: {button.Current.HelpText}");
        guardTarget();
        var started = DateTimeOffset.UtcNow;
        Click(button);
        var log = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexControl", "control.log");
        var watch = Stopwatch.StartNew();
        while (watch.Elapsed < TimeSpan.FromSeconds(30))
        {
            var lines = await File.ReadAllLinesAsync(log);
            var action = "ACT" + id["ActionKey".Length..];
            var receipt = lines.LastOrDefault(line => line.Contains($"pid={pid} ") && line.Contains("micro-action ") &&
                line.Contains($"\"action\":\"{action}\"") &&
                DateTimeOffset.TryParse(line.Split(' ')[0], out var time) && time >= started);
            if (receipt is not null)
            {
                var payload = receipt[(receipt.IndexOf("micro-action ", StringComparison.Ordinal) + 13)..].Trim();
                Console.WriteLine(payload);
                using var result = JsonDocument.Parse(payload);
                if (result.RootElement.GetProperty("disposition").GetString() != "Accepted")
                    throw new Exception($"{id}: {payload}; do not retry an unconfirmed action");
                guardTarget();
                return;
            }
            await Task.Delay(100);
        }
        throw new Exception($"{id}: Micro produced no action result");
    }

    private static void Click(AutomationElement element, bool right = false)
    {
        var point = element.GetClickablePoint();
        var hit = AutomationElement.FromPoint(point);
        if (hit.Current.ProcessId != element.Current.ProcessId) throw new Exception("Click target is covered by another process");
        if (!SetPhysicalCursorPos((int)point.X, (int)point.Y)) throw new Exception("SetPhysicalCursorPos failed");
        var inputs = new[] { new Input { Type = 0, Mouse = new MouseInput { Flags = right ? 0x0008u : 0x0002u } },
            new Input { Type = 0, Mouse = new MouseInput { Flags = right ? 0x0010u : 0x0004u } } };
        if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>()) != inputs.Length) throw new Exception("Mouse SendInput failed");
    }

    private static async Task Until(Func<bool> condition, string stage)
    {
        var watch = Stopwatch.StartNew();
        do
        {
            try { if (condition()) return; }
            catch (ElementNotAvailableException) { /* Re-read observations invalidated by streaming output. */ }
            await Task.Delay(100);
        } while (watch.Elapsed < TimeSpan.FromSeconds(12));
        throw new Exception(stage + " timed out");
    }

    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct MouseInput { public int X, Y; public uint Data, Flags, Time; public nuint ExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] private struct KeyboardInput { public ushort Key, Scan; public uint Flags, Time; public nuint ExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] private struct Input { [FieldOffset(0)] public uint Type; [FieldOffset(8)] public MouseInput Mouse; [FieldOffset(8)] public KeyboardInput Keyboard; }
    [DllImport("user32.dll")] private static extern bool GetPhysicalCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] private static extern bool SetPhysicalCursorPos(int x, int y);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, Input[] inputs, int size);
}
