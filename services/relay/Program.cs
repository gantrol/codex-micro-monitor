using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Channels;

var builder = WebApplication.CreateSlimBuilder(args);
var app = builder.Build();

app.UseWebSockets(new WebSocketOptions
{
    KeepAliveInterval = TimeSpan.FromSeconds(15),
});

var router = new RelayRouter();

app.MapGet("/healthz", () => Results.Json(new
{
    status = "ok",
    activeHosts = router.ActiveHostCount,
    activeDevices = router.ActiveDeviceCount,
    timestampMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
}));

app.Map("/ws/relay", async (HttpContext context) =>
{
    if (!context.WebSockets.IsWebSocketRequest)
    {
        context.Response.StatusCode = StatusCodes.Status400BadRequest;
        return;
    }

    var role = context.Request.Query["role"].ToString();
    var hostId = context.Request.Query["hostId"].ToString();
    var deviceId = context.Request.Query["deviceId"].ToString();

    if (string.IsNullOrWhiteSpace(hostId) ||
        (role is not "host" and not "device") ||
        (role == "device" && string.IsNullOrWhiteSpace(deviceId)))
    {
        context.Response.StatusCode = StatusCodes.Status400BadRequest;
        return;
    }

    using var ws = await context.WebSockets.AcceptWebSocketAsync();
    await router.HandleSessionAsync(ws, role, hostId, deviceId, context.RequestAborted);
});

await app.RunAsync();

internal sealed class RelayPeer : IAsyncDisposable
{
    private readonly WebSocket _ws;
    private readonly Channel<byte[]> _outbound;
    private readonly CancellationTokenSource _cts = new();
    private readonly Task _writerTask;

    public string ConnectionId { get; } = Guid.NewGuid().ToString("N");
    public string Role { get; }
    public string HostId { get; }
    public string DeviceId { get; }

    public RelayPeer(WebSocket ws, string role, string hostId, string deviceId)
    {
        _ws = ws;
        Role = role;
        HostId = hostId;
        DeviceId = deviceId;
        _outbound = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(128)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = false,
        });
        _writerTask = Task.Run(WriteLoopAsync);
    }

    public bool TryEnqueue(byte[] payload) => _outbound.Writer.TryWrite(payload);

    private async Task WriteLoopAsync()
    {
        try
        {
            await foreach (var frame in _outbound.Reader.ReadAllAsync(_cts.Token))
            {
                if (_ws.State != WebSocketState.Open)
                {
                    break;
                }
                await _ws.SendAsync(frame, WebSocketMessageType.Text, endOfMessage: true, _cts.Token);
            }
        }
        catch
        {
            // Connection closed
        }
    }

    public async ValueTask DisposeAsync()
    {
        _outbound.Writer.TryComplete();
        await _cts.CancelAsync();
        try
        {
            await _writerTask;
        }
        catch
        {
            // Ignore writer termination
        }
        _cts.Dispose();
    }
}

internal sealed class RelayRouter
{
    private const int MaxFrameBytes = 256 * 1024;
    private readonly ConcurrentDictionary<string, RelayPeer> _hosts = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, ConcurrentDictionary<string, RelayPeer>> _devicesByHost = new(StringComparer.Ordinal);

    public int ActiveHostCount => _hosts.Count;
    public int ActiveDeviceCount => _devicesByHost.Values.Sum(d => d.Count);

    public async Task HandleSessionAsync(
        WebSocket ws,
        string role,
        string hostId,
        string deviceId,
        CancellationToken cancellationToken)
    {
        await using var peer = new RelayPeer(ws, role, hostId, deviceId);

        if (role == "host")
        {
            _hosts[hostId] = peer;
            BroadcastHostPresence(hostId, online: true);
        }
        else
        {
            var dict = _devicesByHost.GetOrAdd(hostId, _ => new ConcurrentDictionary<string, RelayPeer>(StringComparer.Ordinal));
            dict[deviceId] = peer;
            if (!_hosts.ContainsKey(hostId))
            {
                EnqueueRelayError(peer, "host_offline", $"Host {hostId} is not currently connected to relay.");
            }
        }

        var buffer = new byte[32 * 1024];
        using var ms = new MemoryStream();
        try
        {
            while (ws.State == WebSocketState.Open && !cancellationToken.IsCancellationRequested)
            {
                var result = await ws.ReceiveAsync(buffer, cancellationToken);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    break;
                }
                if (result.MessageType != WebSocketMessageType.Text)
                {
                    continue;
                }

                ms.Write(buffer, 0, result.Count);
                if (ms.Length > MaxFrameBytes)
                {
                    EnqueueRelayError(peer, "frame_too_large", "Relay frame exceeds 256 KB limit.");
                    break;
                }
                if (!result.EndOfMessage)
                {
                    continue;
                }

                var rawBytes = ms.ToArray();
                ms.SetLength(0);
                RouteFrame(peer, rawBytes);
            }
        }
        catch
        {
            // Transport closed
        }
        finally
        {
            if (role == "host")
            {
                if (_hosts.TryGetValue(hostId, out var current) && current.ConnectionId == peer.ConnectionId)
                {
                    _hosts.TryRemove(hostId, out _);
                    BroadcastHostPresence(hostId, online: false);
                }
            }
            else if (_devicesByHost.TryGetValue(hostId, out var dict) &&
                     dict.TryGetValue(deviceId, out var current) &&
                     current.ConnectionId == peer.ConnectionId)
            {
                dict.TryRemove(deviceId, out _);
            }
        }
    }

    private void RouteFrame(RelayPeer sender, byte[] rawBytes)
    {
        JsonNode? node;
        try
        {
            node = JsonNode.Parse(rawBytes);
        }
        catch
        {
            return;
        }
        if (node is not JsonObject obj)
        {
            return;
        }

        var type = obj["type"]?.GetValue<string>();
        if (!string.Equals(type, "relay.envelope", StringComparison.Ordinal))
        {
            return;
        }

        var envHostId = obj["hostID"]?.GetValue<string>();
        var envDeviceId = obj["deviceID"]?.GetValue<string>();
        if (!string.Equals(envHostId, sender.HostId, StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(envDeviceId))
        {
            return;
        }

        if (sender.Role == "device")
        {
            if (!string.Equals(envDeviceId, sender.DeviceId, StringComparison.Ordinal))
            {
                return;
            }
            if (_hosts.TryGetValue(sender.HostId, out var hostPeer))
            {
                hostPeer.TryEnqueue(rawBytes);
            }
            else
            {
                EnqueueRelayError(sender, "host_offline", $"Host {sender.HostId} is offline.");
            }
        }
        else if (sender.Role == "host")
        {
            if (!_devicesByHost.TryGetValue(sender.HostId, out var devices))
            {
                return;
            }
            if (envDeviceId == "*")
            {
                foreach (var dev in devices.Values)
                {
                    dev.TryEnqueue(rawBytes);
                }
            }
            else if (devices.TryGetValue(envDeviceId, out var targetDevice))
            {
                targetDevice.TryEnqueue(rawBytes);
            }
        }
    }

    private void BroadcastHostPresence(string hostId, bool online)
    {
        if (!_devicesByHost.TryGetValue(hostId, out var devices))
        {
            return;
        }
        var msg = JsonSerializer.SerializeToUtf8Bytes(new
        {
            type = online ? "relay.hostOnline" : "relay.hostOffline",
            v = 2,
            payload = new { hostID = hostId },
        });
        foreach (var dev in devices.Values)
        {
            dev.TryEnqueue(msg);
        }
    }

    private static void EnqueueRelayError(RelayPeer peer, string code, string message)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new
        {
            type = "error",
            v = 2,
            payload = new { code, message },
        });
        peer.TryEnqueue(bytes);
    }
}
