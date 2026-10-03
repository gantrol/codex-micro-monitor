using System.Text.Json.Nodes;
using CodexMicro.Codex;

namespace CodexMicro.Codex;

public sealed record CodexNavigationReceipt(string? ThreadId);

public sealed class CodexSoftwareClient : IDisposable, IAsyncDisposable
{
    private readonly KeypadController _controller;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly SemaphoreSlim _operations = new(1);
    private readonly object _shutdownGate = new();
    private Task? _shutdown;
    private volatile bool _disposed;

    public CodexSoftwareClient() : this(null) { }

    public CodexSoftwareClient(Action<string>? openUri)
    {
        _controller = new(openUri: openUri);
    }

    public Task<CodexNavigationReceipt> OpenThreadAsync(
        string threadId,
        Func<Task<bool>>? canApply = null,
        CancellationToken cancellationToken = default) =>
        NavigateAsync(
            "open_keypad_thread",
            new JsonObject { ["thread_id"] = JsonSupport.ThreadId(threadId) },
            canApply,
            cancellationToken);

    public Task<CodexNavigationReceipt> CreateDraftAsync(
        Func<Task<bool>>? canApply = null,
        CancellationToken cancellationToken = default) =>
        NavigateAsync("new_keypad_thread", new JsonObject(), canApply, cancellationToken);

    private async Task<CodexNavigationReceipt> NavigateAsync(
        string command,
        JsonObject arguments,
        Func<Task<bool>>? canApply,
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        using var operation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken, _lifetime.Token);
        await _operations.WaitAsync(operation.Token).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var result = await Task.Run(
                () => _controller.ExecuteAsync(command, arguments, operation.Token, canApply),
                operation.Token).ConfigureAwait(false);
            if (result["opened"]?.GetValue<bool>() != true)
            {
                throw new IOException("Codex navigation was not acknowledged");
            }

            return new CodexNavigationReceipt(result.Text("threadId"));
        }
        finally
        {
            _operations.Release();
        }
    }

    public void Dispose()
    {
        lock (_shutdownGate)
        {
            if (_disposed) return;
            _disposed = true;
            _lifetime.Cancel();
            _shutdown = ShutdownAsync();
        }
    }

    public ValueTask DisposeAsync()
    {
        Dispose();
        lock (_shutdownGate)
        {
            return new ValueTask(_shutdown!);
        }
    }

    private async Task ShutdownAsync()
    {
        await _operations.WaitAsync().ConfigureAwait(false);
        try
        {
            await _controller.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException)
        {
            SoftwareControlDiagnostics.Write("software-client-shutdown", error);
        }
        finally
        {
            _lifetime.Dispose();
            _operations.Release();
        }
    }
}
