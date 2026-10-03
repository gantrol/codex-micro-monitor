namespace CodexMicro.Desktop.Services;

internal static class CodexServiceTier
{
    // The catalog calls the speed tier "fast"; the desktop stores it as "priority".
    internal static bool IsFast(string? value) => value is "priority" or "fast";
}
