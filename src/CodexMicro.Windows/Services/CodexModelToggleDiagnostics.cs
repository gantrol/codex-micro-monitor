#if DEBUG
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading.Channels;

namespace CodexMicro.Desktop.Services;

/// <summary>
/// Keeps a bounded local JSONL trail for model and composer control failures.
/// It records only task/model identifiers and timing, never prompts or output.
/// </summary>
internal static class CodexModelToggleDiagnostics
{
    private sealed record Entry(string? Json, TaskCompletionSource? Flushed = null);
    private static readonly Channel<Entry> Pending = Channel.CreateBounded<Entry>(new BoundedChannelOptions(512)
    {
        SingleReader = true,
        FullMode = BoundedChannelFullMode.Wait,
    });
    private static long _dropped;
    private static readonly string? App = System.Reflection.Assembly.GetEntryAssembly()?.GetName().Name;
    private static readonly string? Build = System.Reflection.Assembly.GetEntryAssembly()?
        .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
        .OfType<System.Reflection.AssemblyInformationalVersionAttribute>().FirstOrDefault()?.InformationalVersion;

    static CodexModelToggleDiagnostics() => _ = Task.Run(WritePendingAsync);

    internal static string LogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "CodexMicro",
        "logs",
        $"model-toggle-{Environment.ProcessId}.jsonl");

    internal static void Record(
        CodexModelToggleResult result,
        TimeSpan elapsed)
    {
        try
        {
            var entry = JsonSerializer.Serialize(new
            {
                timestampUtc = DateTimeOffset.UtcNow,
                pid = Environment.ProcessId,
                app = App,
                build = Build,
                operationId = Activity.Current?.Id,
                result.Succeeded,
                result.Error,
                result.Detail,
                result.ThreadId,
                previousModel = result.Previous.ToString(),
                currentModel = result.Current.ToString(),
                result.PreviousEffort,
                result.CurrentEffort,
                elapsedMilliseconds = Math.Round(elapsed.TotalMilliseconds, 1),
            });
            Enqueue(entry);
        }
        catch
        {
            // Diagnostics must never turn a successful toggle into a failure.
        }
    }

    internal static void RecordStage(string stage, object? detail = null)
    {
        try
        {
            var entry = JsonSerializer.Serialize(new
            {
                timestampUtc = DateTimeOffset.UtcNow,
                pid = Environment.ProcessId,
                app = App,
                build = Build,
                operationId = Activity.Current?.Id,
                stage,
                detail,
            });
            Enqueue(entry);
        }
        catch
        {
            // Diagnostics must never affect the model-toggle operation.
        }
    }

    private static void Enqueue(string json)
    {
        if (!Pending.Writer.TryWrite(new(json))) Interlocked.Increment(ref _dropped);
    }

    internal static async Task FlushAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            await Pending.Writer.WriteAsync(new(null, completion), timeout.Token).ConfigureAwait(false);
            await completion.Task.WaitAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { Debug.WriteLine("Control diagnostics flush timed out."); }
    }

    private static async Task WritePendingAsync()
    {
        await foreach (var entry in Pending.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            if (entry.Flushed is { } completion) { completion.TrySetResult(); continue; }
            var dropped = Interlocked.Exchange(ref _dropped, 0);
            try
            {
                // Only this worker touches directory/rotation metadata; rotate at 1 MiB.
                Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
                if (File.Exists(LogPath) && new FileInfo(LogPath).Length >= 1024 * 1024)
                    File.Move(LogPath, LogPath + ".previous", overwrite: true);
                var gap = dropped == 0 ? "" : JsonSerializer.Serialize(new
                {
                    timestampUtc = DateTimeOffset.UtcNow, pid = Environment.ProcessId,
                    stage = "diagnostics-dropped", count = dropped,
                }) + Environment.NewLine;
                await File.AppendAllTextAsync(LogPath, gap + entry.Json + Environment.NewLine).ConfigureAwait(false);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                Interlocked.Add(ref _dropped, dropped + 1);
                Debug.WriteLine($"Control diagnostics unavailable: {error.GetType().Name}");
            }
        }
    }
}
#endif
