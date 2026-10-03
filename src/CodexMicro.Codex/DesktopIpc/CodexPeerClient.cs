using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.IO;
using System.IO.Pipes;
using System.Text.Json.Nodes;

namespace CodexMicro.Codex;

internal sealed class CodexPeerClient : IAsyncDisposable
{
    private readonly string _pipeName;
    internal CodexPeerClient(string pipeName = "codex-ipc") => _pipeName = pipeName;
    private readonly SemaphoreSlim _connectGate = new(1);
    private readonly SemaphoreSlim _writeGate = new(1);
    private readonly ConcurrentDictionary<string, TaskCompletionSource<JsonObject>> _pending = new();
    private readonly CancellationTokenSource _lifetime = new();
    private NamedPipeClientStream? _pipe;
    private Task? _reader;
    private string? _clientId;
    internal event Action<JsonObject>? Broadcast;
    internal event Action? Disconnected;

    internal async Task ConnectAsync(CancellationToken cancellationToken)
    {
        await _connectGate.WaitAsync(cancellationToken);
        try
        {
            if (_pipe?.IsConnected == true && _clientId is not null) return;
            _pipe?.Dispose();
            if (_reader is not null) await _reader;
            _pipe = null;
            _clientId = null;
            var pipe = new NamedPipeClientStream(".", _pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _lifetime.Token);
            timeout.CancelAfter(TimeSpan.FromSeconds(4));
            try { await pipe.ConnectAsync(timeout.Token); }
            catch { pipe.Dispose(); throw; }
            _pipe = pipe;
            _clientId = "initializing-client";
            _reader = ReadAsync(pipe);
            try
            {
                var initialized = await RequestAsync("initialize", 0, new { clientType = "codex-micro-plugin" }, null, timeout.Token);
                _clientId = initialized["result"]?.Text("clientId") ?? throw new IOException("Invalid Codex initialize response");
            }
            catch
            {
                _clientId = null;
                pipe.Dispose();
                throw;
            }
        }
        finally { _connectGate.Release(); }
    }

    internal async Task<JsonObject> RequestAsync(string method, int version, object parameters, string? target, CancellationToken cancellationToken)
    {
        var id = Guid.NewGuid().ToString();
        var completion = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[id] = completion;
        try
        {
            await WriteAsync(new
            {
                type = "request", requestId = id, sourceClientId = _clientId,
                method, version, @params = parameters, targetClientId = target, timeoutMs = 10_000
            }, cancellationToken);
            var response = await completion.Task.WaitAsync(TimeSpan.FromSeconds(12), cancellationToken);
            if (response.Text("method") != method || response.Text("resultType") != "success")
                throw new IOException(response.Text("error") ?? "Codex rejected the request");
            return response;
        }
        finally { _pending.TryRemove(id, out _); }
    }

    internal Task FollowAsync(string threadId, string owner, bool following, CancellationToken cancellationToken) =>
        WriteAsync(new
        {
            type = "broadcast", method = "thread-stream-following-changed", version = 1,
            sourceClientId = _clientId, targetClientIds = new[] { owner },
            @params = new { conversationId = threadId, hostId = "local", following }
        }, cancellationToken);

    private async Task WriteAsync(object message, CancellationToken cancellationToken)
    {
        var payload = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(message);
        var frame = new byte[payload.Length + 4];
        BinaryPrimitives.WriteInt32LittleEndian(frame, payload.Length);
        payload.CopyTo(frame, 4);
        await _writeGate.WaitAsync(cancellationToken);
        try
        {
            var pipe = _pipe ?? throw new IOException("Codex is not connected");
            await pipe.WriteAsync(frame, cancellationToken);
            await pipe.FlushAsync(cancellationToken);
        }
        finally { _writeGate.Release(); }
    }

    private async Task ReadAsync(NamedPipeClientStream pipe)
    {
        try
        {
            var header = new byte[4];
            while (!_lifetime.IsCancellationRequested)
            {
                await pipe.ReadExactlyAsync(header, _lifetime.Token);
                var length = BinaryPrimitives.ReadInt32LittleEndian(header);
                if (length is <= 0 or > 16 * 1024 * 1024) throw new IOException("Invalid Codex frame");
                var payload = new byte[length];
                await pipe.ReadExactlyAsync(payload, _lifetime.Token);
                if (JsonNode.Parse(payload) is not JsonObject message) throw new IOException("Invalid Codex message");
                switch (message.Text("type"))
                {
                    case "response":
                        if (_pending.TryRemove(message.Required("requestId"), out var pending)) pending.TrySetResult(message);
                        break;
                    case "client-discovery-request":
                        await WriteAsync(new { type = "client-discovery-response", requestId = message.Required("requestId"), response = new { canHandle = false } }, _lifetime.Token);
                        break;
                    case "broadcast":
                        Broadcast?.Invoke(message);
                        break;
                }
            }
        }
        catch (Exception error)
        {
            foreach (var pending in _pending.Values) pending.TrySetException(new IOException("Codex disconnected; mutation outcome may be unknown", error));
            _pending.Clear();
        }
        finally
        {
            pipe.Dispose();
            if (ReferenceEquals(_pipe, pipe)) { _clientId = null; Disconnected?.Invoke(); }
        }
    }

    public async ValueTask DisposeAsync()
    {
        _lifetime.Cancel();
        _pipe?.Dispose();
        if (_reader is not null) await _reader;
        _lifetime.Dispose();
    }
}
