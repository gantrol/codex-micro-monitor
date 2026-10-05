using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows.Automation;
using CodexMicro.Desktop.Services;
using AgentController.Adapters.Codex.Windows;

// External-process verification: the same running executable the user clicks,
// with no private-field changes, routed-event injection or replacement transport.
internal static class RunningControlsVerification
{
    internal static async Task<int> InspectAsync(string reportPath)
    {
        var micros = Process.GetProcessesByName("CodexMicro");
        try
        {
            if (micros.Length != 1) throw new InvalidOperationException($"Expected one running Micro, found {micros.Length}");
            var micro = AutomationElement.RootElement.FindAll(TreeScope.Children,
                new PropertyCondition(AutomationElement.ProcessIdProperty, micros[0].Id))
                .Cast<AutomationElement>().SelectMany(root => root.FindAll(TreeScope.Descendants,
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button)).Cast<AutomationElement>())
                .Select(Describe).ToArray();
            if (!CodexWindowActivator.TryFindMainWindow(out var window, out _))
                throw new InvalidOperationException("Codex window unavailable");
            var codex = AutomationElement.FromHandle(window);
            var documents = codex.FindAll(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Document))
                .Cast<AutomationElement>().Where(element => !element.Current.IsOffscreen)
                .Select(element => new
                {
                    element.Current.AutomationId,
                    url = element.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern)
                        ? ((ValuePattern)pattern).Current.Value : null,
                }).ToArray();
            var selected = await new CodexSelectedThreadReader().ReadAsync();
            var titles = CodexSelectedThreadReader.ReadSelectedTitles(window);
            var sidebar = codex.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.IsOffscreenProperty, false))
                .Cast<AutomationElement>().Where(element => element.Current.ClassName.Split(' ').Contains("sidebar-item") &&
                    titles.Contains(element.Current.Name)).Select(element => new
                    {
                        node = Describe(element),
                        value = element.TryGetCurrentPattern(ValuePattern.Pattern, out var value) ? ((ValuePattern)value).Current.Value : null,
                        patterns = element.GetSupportedPatterns().Select(pattern => pattern.ProgrammaticName).ToArray(),
                        children = element.FindAll(TreeScope.Children, Condition.TrueCondition).Cast<AutomationElement>().Select(Describe).ToArray(),
                        ancestors = Ancestors(element).ToArray(),
                    }).ToArray();
            using var session = new WindowsCodexUiDesktop().Capture();
            var ui = session?.Read();
            var report = new { timeUtc = DateTimeOffset.UtcNow, microPid = micros[0].Id,
                selected, documents, selectedTitles = titles, sidebar, micro,
                native = new { ui?.IsDraft, ui?.Busy, ui?.ComposerControls, ui?.ModeControls } };
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(reportPath))!);
            await File.WriteAllTextAsync(reportPath, JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine($"Inspection saved: {reportPath}; selected={selected ?? "unknown"}");
            return 0;
        }
        finally { foreach (var process in micros) process.Dispose(); }
    }

    private static object Describe(AutomationElement element) => new
    {
        id = element.Current.AutomationId,
        name = element.Current.Name,
        enabled = element.Current.IsEnabled,
        help = element.Current.HelpText,
        status = element.Current.ItemStatus,
    };

    private static IEnumerable<object> Ancestors(AutomationElement element)
    {
        for (var i = 0; i < 8; i++)
        {
            element = TreeWalker.ControlViewWalker.GetParent(element);
            if (element is null) yield break;
            yield return new { element.Current.AutomationId, element.Current.ClassName,
                role = element.Current.ControlType.ProgrammaticName };
        }
    }
}
