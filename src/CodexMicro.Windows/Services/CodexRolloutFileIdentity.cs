using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CodexMicro.Desktop.Services;

internal static class CodexRolloutFileIdentity
{
    internal static string Read(FileStream stream)
    {
        // Windows exposes this 24-byte metadata query synchronously. It runs
        // in the monitor's existing background file reader, on the same handle
        // used for the subsequent read, without opening or scanning the file.
        if (!GetFileInformationByHandleEx(stream.SafeFileHandle, FileIdInfoClass,
            out var identity, (uint)Marshal.SizeOf<FileIdInfo>()))
        {
            throw new IOException("Unable to identify the rollout file.",
                new Win32Exception(Marshal.GetLastWin32Error()));
        }

        return FormattableString.Invariant(
            $"{identity.VolumeSerialNumber:X16}:{identity.FileIdLow:X16}{identity.FileIdHigh:X16}");
    }

    private const int FileIdInfoClass = 18;

    [StructLayout(LayoutKind.Sequential)]
    private struct FileIdInfo
    {
        public ulong VolumeSerialNumber;
        public ulong FileIdLow;
        public ulong FileIdHigh;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle file,
        int informationClass,
        out FileIdInfo information,
        uint bufferSize);
}
