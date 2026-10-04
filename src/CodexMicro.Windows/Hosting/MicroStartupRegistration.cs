using Microsoft.Win32;
using System.Runtime.InteropServices;
using Windows.ApplicationModel;

namespace CodexMicro.DesktopHost;

internal sealed class MicroStartupRegistration(string valueName = "CodexMicroKeypad")
{
    internal const string StartupTaskId = "MicroMonitorStartup";
    private const string RunKeyPath =
        @"Software\Microsoft\Windows\CurrentVersion\Run";

    internal async Task<(bool IsEnabled, bool CanChange)> GetStateAsync()
    {
        if (IsPackaged)
        {
            var task = await StartupTask.GetAsync(StartupTaskId);
            return (task.State is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy,
                task.State is StartupTaskState.Enabled or StartupTaskState.Disabled);
        }

        return await Task.Run(() =>
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
            return (key?.GetValue(valueName) is string value &&
                !string.IsNullOrWhiteSpace(value), true);
        });
    }

    internal async Task SetEnabledAsync(bool enabled)
    {
        if (IsPackaged)
        {
            var task = await StartupTask.GetAsync(StartupTaskId);
            if (enabled)
                await task.RequestEnableAsync();
            else
                task.Disable();
            return;
        }

        await Task.Run(() => SetUnpackagedEnabled(enabled));
    }

    private void SetUnpackagedEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath) ??
            throw new InvalidOperationException(
                "Could not open the current-user startup registry key.");
        if (!enabled)
        {
            key.DeleteValue(valueName, throwOnMissingValue: false);
            return;
        }

        var executable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable))
        {
            throw new InvalidOperationException(
                "Could not resolve the Codex Micro executable path.");
        }

        key.SetValue(
            valueName,
            $"\"{executable}\" --background",
            RegistryValueKind.String);
    }

    private static bool IsPackaged
    {
        get
        {
            uint length = 0;
            return GetCurrentPackageFullName(ref length, IntPtr.Zero) == 122;
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetCurrentPackageFullName(ref uint length, IntPtr name);
}
