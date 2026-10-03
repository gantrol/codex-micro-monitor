using System.IO;

namespace CodexMicro.Codex;

internal static class SoftwareControlDiagnostics
{
    private static readonly object Gate = new();

    internal static void Write(string stage, Exception? error = null)
    {
        try
        {
            var entry = System.Reflection.Assembly.GetEntryAssembly()?.GetName();
            var isController = entry?.Name == "AgentController";
            var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                isController ? "AgentController" : "CodexMicro");
            lock (Gate)
            {
                Directory.CreateDirectory(directory);
                var path = Path.Combine(directory, isController ? "software-control.log" :
                    entry?.Name == "CodexMicro.Plugin" ? "plugin-startup.log" : "keypad-startup.log");
                if (File.Exists(path) && new FileInfo(path).Length > 256 * 1024)
                    File.Move(path, path + ".previous", overwrite: true);
                File.AppendAllText(path, $"{DateTimeOffset.UtcNow:O} pid={Environment.ProcessId} v{entry?.Version} {stage} {error}\n");
            }
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException) { }
    }
}
