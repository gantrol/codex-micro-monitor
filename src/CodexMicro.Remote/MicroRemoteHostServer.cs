using System.Collections.Concurrent;
using System.Net;
using System.Net.WebSockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using CodexMicro.Protocol;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;

namespace CodexMicro.Remote;

public sealed class MicroRemoteHostServer : IAsyncDisposable
{
    private sealed class ConnectedSession
    {
        public required string SessionId { get; init; }
        public required WebSocket WebSocket { get; init; }
        public SemaphoreSlim SendLock { get; } = new(1, 1);
        public string? DeviceId { get; set; }
        public string DeviceName { get; set; } = "iOS Client";
        public string? DevicePublicKey { get; set; }
        public string Role { get; set; } = "readOnly";
        public bool IsAuthenticated { get; set; }
    }

    private readonly IMicroRemoteBackend _backend;
    private readonly RemotePersistentStore _store;
    private readonly X509Certificate2 _certificate;
    private readonly string _certPinSha256;
    private readonly int _port;
    private readonly string _hostName;
    private readonly ConcurrentDictionary<string, ConnectedSession> _sessions = new(StringComparer.Ordinal);
    private readonly Lock _leaseLock = new();

    private WebApplication? _app;
    private string? _activeWriterDeviceId;
    private string? _activeWriterName;
    private int _revision = 1;

    public string HostId => _store.HostId;
    public string CertPinSha256 => _certPinSha256;
    public int Port => _port;

    public MicroRemoteHostServer(
        IMicroRemoteBackend backend,
        string storageDirectory,
        int port = MicroRemoteConstants.DefaultPort,
        string? hostName = null)
    {
        _backend = backend;
        _store = new RemotePersistentStore(storageDirectory);
        (_certificate, _certPinSha256) = HostCertificateManager.LoadOrCreateCertificate(storageDirectory, _store.HostId);
        _port = port;
        _hostName = string.IsNullOrWhiteSpace(hostName) ? Environment.MachineName : hostName;
    }

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_app is not null)
        {
            return;
        }

        var builder = WebApplication.CreateSlimBuilder();
        builder.WebHost.UseKestrel(options =>
        {
            options.Listen(IPAddress.Any, _port, listenOptions =>
            {
                listenOptions.UseHttps(_certificate);
            });
        });

        var app = builder.Build();
        app.UseWebSockets(new WebSocketOptions
        {
            KeepAliveInterval = TimeSpan.FromSeconds(15),
        });

        app.Map(MicroRemoteConstants.DefaultWebSocketPath, async (HttpContext context) =>
        {
            if (!context.WebSockets.IsWebSocketRequest)
            {
                context.Response.StatusCode = StatusCodes.Status400BadRequest;
                return;
            }

            using var ws = await context.WebSockets.AcceptWebSocketAsync();
            await RunWebSocketSessionAsync(ws, context.RequestAborted);
        });

        await app.StartAsync(cancellationToken);
        _app = app;
    }

    public MicroRemotePairPayload CreatePairingPayload(string mode = "direct", string? relayUrl = null)
    {
        var (token, expiresAtMs) = _store.IssuePairingToken(ttlSeconds: 300);
        var endpoints = HostCertificateManager.DiscoverEndpoints(_port, useTls: true);
        return new MicroRemotePairPayload(
            Version: MicroRemoteConstants.ProtocolVersion,
            Mode: mode,
            HostID: _store.HostId,
            HostName: _hostName,
            Platform: "windows",
            Endpoints: endpoints,
            RelayURL: relayUrl,
            CertPinSHA256: _certPinSha256,
            HostPublicKey: _store.HostPublicKeyBase64,
            PairingToken: token,
            ExpiresAtMs: expiresAtMs);
    }

    public async Task RevokeDeviceAsync(string deviceId, CancellationToken cancellationToken = default)
    {
        _store.RevokeDevice(deviceId);
        foreach (var (sessionId, session) in _sessions)
        {
            if (!string.Equals(session.DeviceId, deviceId, StringComparison.Ordinal))
            {
                continue;
            }

            await SendEnvelopeAsync(session, "auth.revoked", null, new
            {
                deviceID = deviceId,
                reason = "Device access was revoked on Host.",
            }, cancellationToken);

            try
            {
                await session.WebSocket.CloseAsync(WebSocketCloseStatus.PolicyViolation, "Revoked", cancellationToken);
            }
            catch
            {
                // Ignore close errors
            }
            _sessions.TryRemove(sessionId, out _);
        }

        bool leaseChanged = false;
        lock (_leaseLock)
        {
            if (string.Equals(_activeWriterDeviceId, deviceId, StringComparison.Ordinal))
            {
                _activeWriterDeviceId = null;
                _activeWriterName = null;
                ReassignWriterLocked();
                leaseChanged = true;
            }
        }
        if (leaseChanged)
        {
            await BroadcastLeaseAsync(null, cancellationToken);
        }
    }

    private async Task RunWebSocketSessionAsync(WebSocket ws, CancellationToken cancellationToken)
    {
        var sessionId = "ws-" + Guid.NewGuid().ToString("N");
        var session = new ConnectedSession
        {
            SessionId = sessionId,
            WebSocket = ws,
        };
        _sessions[sessionId] = session;

        var buffer = new byte[64 * 1024];
        using var messageStream = new MemoryStream();
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

                messageStream.Write(buffer, 0, result.Count);
                if (messageStream.Length > 1024 * 1024)
                {
                    break;
                }
                if (!result.EndOfMessage)
                {
                    continue;
                }

                var rawText = Encoding.UTF8.GetString(messageStream.GetBuffer(), 0, (int)messageStream.Length);
                messageStream.SetLength(0);
                await HandleFrameAsync(session, rawText, cancellationToken);
            }
        }
        catch
        {
            // Connection closed or aborted
        }
        finally
        {
            _sessions.TryRemove(sessionId, out _);
            bool leaseChanged = false;
            lock (_leaseLock)
            {
                if (session.DeviceId is not null &&
                    string.Equals(_activeWriterDeviceId, session.DeviceId, StringComparison.Ordinal) &&
                    !_sessions.Values.Any(s => s.IsAuthenticated && string.Equals(s.DeviceId, session.DeviceId, StringComparison.Ordinal)))
                {
                    _activeWriterDeviceId = null;
                    _activeWriterName = null;
                    ReassignWriterLocked();
                    leaseChanged = true;
                }
            }
            if (leaseChanged)
            {
                await BroadcastLeaseAsync(null, CancellationToken.None);
            }
        }
    }

    private async Task HandleFrameAsync(ConnectedSession session, string rawText, CancellationToken cancellationToken)
    {
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(rawText);
        }
        catch
        {
            return;
        }
        if (root is not JsonObject obj)
        {
            return;
        }

        var type = obj["type"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(type))
        {
            return;
        }
        var requestId = obj["requestID"]?.GetValue<string>();
        var payload = obj["payload"] as JsonObject ?? new JsonObject();

        switch (type)
        {
            case "pair.exchange":
                await HandlePairExchangeAsync(session, payload, requestId, cancellationToken);
                break;

            case "hello":
                await HandleHelloAsync(session, payload, requestId, cancellationToken);
                break;

            case "ping":
            {
                var clientTs = payload["clientTimestampMs"]?.GetValue<long>() ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                await SendEnvelopeAsync(session, "pong", requestId, new
                {
                    clientTimestampMs = clientTs,
                    serverTimestampMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                }, cancellationToken);
                break;
            }

            case "session.takeover":
                if (!session.IsAuthenticated || session.DeviceId is null)
                {
                    await SendErrorAsync(session, requestId, "unauthorized", "Authenticate before requesting takeover.", cancellationToken);
                    return;
                }
                lock (_leaseLock)
                {
                    _activeWriterDeviceId = session.DeviceId;
                    _activeWriterName = session.DeviceName;
                    foreach (var s in _sessions.Values)
                    {
                        s.Role = string.Equals(s.DeviceId, _activeWriterDeviceId, StringComparison.Ordinal) ? "readWrite" : "readOnly";
                    }
                }
                await BroadcastLeaseAsync(requestId, cancellationToken);
                break;

            case "state.requestSnapshot":
                if (!session.IsAuthenticated)
                {
                    await SendErrorAsync(session, requestId, "unauthorized", "Authenticate before requesting snapshot.", cancellationToken);
                    return;
                }
                var snap = await _backend.GetSnapshotAsync(_store.HostId, _hostName, Interlocked.Increment(ref _revision), cancellationToken);
                await SendEnvelopeAsync(session, "state.snapshot", requestId, snap, cancellationToken);
                break;

            case "threads.list":
                if (!session.IsAuthenticated)
                {
                    await SendErrorAsync(session, requestId, "unauthorized", "Authenticate before listing threads.", cancellationToken);
                    return;
                }
                var query = payload["query"]?.GetValue<string>();
                var cursor = payload["cursor"]?.GetValue<string>();
                var limit = payload["limit"]?.GetValue<int>() ?? 30;
                var listResult = await _backend.ListThreadsAsync(query, cursor, limit, _revision, cancellationToken);
                await SendEnvelopeAsync(session, "threads.list.result", requestId, listResult, cancellationToken);
                break;

            case "thread.detail.read":
                if (!session.IsAuthenticated)
                {
                    await SendErrorAsync(session, requestId, "unauthorized", "Authenticate before reading thread detail.", cancellationToken);
                    return;
                }
                var detailThreadId = payload["threadID"]?.GetValue<string>() ?? string.Empty;
                var detailResult = await _backend.ReadThreadDetailAsync(detailThreadId, _revision, cancellationToken);
                await SendEnvelopeAsync(session, "thread.detail.result", requestId, detailResult, cancellationToken);
                break;

            case "command.queryResult":
                if (!session.IsAuthenticated || session.DeviceId is null)
                {
                    await SendErrorAsync(session, requestId, "unauthorized", "Authenticate before querying command results.", cancellationToken);
                    return;
                }
                var targetReqId = payload["targetRequestID"]?.GetValue<string>() ?? requestId ?? string.Empty;
                var queried = _store.QueryCommand(session.DeviceId, targetReqId) ?? new MicroRemoteCommandAckPayload(
                    CommandType: "unknown",
                    Status: "unknown",
                    Revision: _revision,
                    ErrorCode: "command_not_found",
                    Message: $"No ledger record found for request {targetReqId}.");
                await SendEnvelopeAsync(session, "command.ack", targetReqId, queried, cancellationToken);
                break;

            default:
                await HandleMutatingCommandAsync(session, type, payload, requestId, cancellationToken);
                break;
        }
    }

    private async Task HandlePairExchangeAsync(ConnectedSession session, JsonObject payload, string? requestId, CancellationToken cancellationToken)
    {
        var pairingToken = payload["pairingToken"]?.GetValue<string>() ?? string.Empty;
        var deviceId = payload["deviceID"]?.GetValue<string>() ?? ("ios-" + Guid.NewGuid().ToString("N")[..8]);
        var deviceName = payload["deviceName"]?.GetValue<string>() ?? "iPhone";
        var platform = payload["platform"]?.GetValue<string>() ?? "ios";
        var devicePublicKey = payload["devicePublicKey"]?.GetValue<string>();

        var deviceToken = _store.ExchangePairingToken(pairingToken, deviceId, deviceName, platform, devicePublicKey);
        if (deviceToken is null)
        {
            await SendErrorAsync(session, requestId, "invalid_pairing_token", "Pairing token is invalid, expired, or already used.", cancellationToken);
            return;
        }

        await SendEnvelopeAsync(session, "pair.accepted", requestId, new
        {
            hostID = _store.HostId,
            hostName = _hostName,
            hostPlatform = "windows",
            deviceID = deviceId,
            deviceToken,
            hostPublicKey = _store.HostPublicKeyBase64,
            certPinSHA256 = _certPinSha256,
            endpoints = HostCertificateManager.DiscoverEndpoints(_port, useTls: true),
        }, cancellationToken);
    }

    private async Task HandleHelloAsync(ConnectedSession session, JsonObject payload, string? requestId, CancellationToken cancellationToken)
    {
        var deviceId = payload["deviceID"]?.GetValue<string>() ?? "legacy-ios-device";
        var deviceName = payload["deviceName"]?.GetValue<string>() ?? "iPhone";
        var rawToken = payload["deviceToken"]?.GetValue<string>() ?? payload["token"]?.GetValue<string>() ?? string.Empty;
        var devicePubKey = payload["devicePublicKey"]?.GetValue<string>();

        var record = _store.AuthenticateDevice(deviceId, rawToken);
        if (record is null)
        {
            var exchanged = _store.ExchangePairingToken(rawToken, deviceId, deviceName, "ios", devicePubKey);
            if (exchanged is not null)
            {
                record = _store.AuthenticateDevice(deviceId, exchanged);
            }
        }

        if (record is null)
        {
            await SendErrorAsync(session, requestId, "auth_failed", "Invalid or revoked device credentials.", cancellationToken);
            return;
        }

        session.DeviceId = record.DeviceId;
        session.DeviceName = record.DeviceName;
        session.DevicePublicKey = devicePubKey ?? record.DevicePublicKey;
        session.IsAuthenticated = true;

        lock (_leaseLock)
        {
            if (_activeWriterDeviceId is null || string.Equals(_activeWriterDeviceId, record.DeviceId, StringComparison.Ordinal))
            {
                _activeWriterDeviceId = record.DeviceId;
                _activeWriterName = record.DeviceName;
                session.Role = "readWrite";
            }
            else
            {
                session.Role = "readOnly";
            }
        }

        await SendEnvelopeAsync(session, "hello.ok", requestId, new
        {
            protocolVersion = MicroRemoteConstants.ProtocolVersion,
            minSupportedVersion = MicroRemoteConstants.MinSupportedVersion,
            hostID = _store.HostId,
            hostName = _hostName,
            hostPlatform = "windows",
            role = session.Role,
            activeWriterDeviceID = _activeWriterDeviceId,
            activeWriterName = _activeWriterName,
            canTakeover = true,
        }, cancellationToken);

        var snap = await _backend.GetSnapshotAsync(_store.HostId, _hostName, Interlocked.Increment(ref _revision), cancellationToken);
        await SendEnvelopeAsync(session, "state.snapshot", null, snap, cancellationToken);
    }

    private async Task HandleMutatingCommandAsync(
        ConnectedSession session,
        string type,
        JsonObject payload,
        string? requestId,
        CancellationToken cancellationToken)
    {
        if (!session.IsAuthenticated || session.DeviceId is null)
        {
            await SendErrorAsync(session, requestId, "unauthorized", "Authenticate before sending control commands.", cancellationToken);
            return;
        }

        if (!string.Equals(session.Role, "readWrite", StringComparison.Ordinal))
        {
            var rejected = new MicroRemoteCommandAckPayload(
                CommandType: type,
                Status: "rejected",
                Revision: _revision,
                ErrorCode: "read_only_lease",
                Message: "Session is in read-only mode. Take over control first.");
            await SendEnvelopeAsync(session, "command.ack", requestId, rejected, cancellationToken);
            return;
        }

        var reqId = requestId ?? Guid.NewGuid().ToString("D");
        var threadId = payload["threadID"]?.GetValue<string>() ?? string.Empty;
        var turnId = payload["turnID"]?.GetValue<string>();
        var approvalRequestId = payload["approvalRequestID"]?.GetValue<string>();
        var payloadHash = ComputeCanonicalPayloadHash(type, payload);

        var begin = _store.BeginOrReuseCommand(
            session.DeviceId,
            reqId,
            payloadHash,
            type,
            _revision,
            threadId,
            turnId,
            approvalRequestId);

        if (begin.Kind == LedgerBeginOutcomeKind.PayloadConflict)
        {
            await SendErrorAsync(session, reqId, "payload_conflict", "Request ID reused with different command payload.", cancellationToken);
            return;
        }
        if (begin.Kind == LedgerBeginOutcomeKind.Existing && begin.ExistingAck is not null)
        {
            await SendEnvelopeAsync(session, "command.ack", reqId, begin.ExistingAck, cancellationToken);
            return;
        }

        MicroSendResult sendResult;
        try
        {
            sendResult = type switch
            {
                "thread.select" => await _backend.SelectThreadAsync(
                    threadId,
                    payload["openInDesktop"]?.GetValue<bool>() ?? false,
                    cancellationToken),
                "settings.setModel" => await _backend.SetModelAsync(
                    threadId,
                    payload["model"]?.GetValue<string>() ?? string.Empty,
                    payload["effort"]?.GetValue<string>(),
                    cancellationToken),
                "settings.setEffort" => await _backend.SetEffortAsync(
                    threadId,
                    payload["effort"]?.GetValue<string>() ?? string.Empty,
                    cancellationToken),
                "settings.stepEffort" => await _backend.StepEffortAsync(
                    threadId,
                    payload["delta"]?.GetValue<int>() ?? 1,
                    cancellationToken),
                "settings.setFastMode" => await _backend.SetFastModeAsync(
                    threadId,
                    payload["enabled"]?.GetValue<bool>() ?? false,
                    cancellationToken),
                "settings.setPlanMode" => await _backend.SetPlanModeAsync(
                    threadId,
                    payload["enabled"]?.GetValue<bool>() ?? false,
                    cancellationToken),
                "approval.accept" => await _backend.ReplyApprovalAsync(
                    threadId,
                    approvalRequestId ?? string.Empty,
                    payload["approvalContentHash"]?.GetValue<string>(),
                    accept: true,
                    cancellationToken),
                "approval.decline" => await _backend.ReplyApprovalAsync(
                    threadId,
                    approvalRequestId ?? string.Empty,
                    payload["approvalContentHash"]?.GetValue<string>(),
                    accept: false,
                    cancellationToken),
                "turn.stop" => await _backend.StopTurnAsync(
                    threadId,
                    turnId ?? string.Empty,
                    cancellationToken),
                "turn.sendText" => await _backend.SendTextAsync(
                    threadId,
                    payload["text"]?.GetValue<string>() ?? string.Empty,
                    cancellationToken),
                _ => MicroSendResult.NotSent($"Unsupported command: {type}"),
            };
        }
        catch (Exception ex)
        {
            sendResult = new MicroSendResult(MicroSendDisposition.Rejected, 0, 1, -1, ex.Message);
        }

        var (status, errorCode, message) = sendResult.Disposition switch
        {
            MicroSendDisposition.Accepted => ("completed", null, null),
            MicroSendDisposition.OutcomeUnknown => ("unknown", "outcome_unknown", sendResult.Detail),
            _ => ("rejected", "command_rejected", sendResult.Detail),
        };

        var rev = Interlocked.Increment(ref _revision);
        var ack = _store.CompleteCommand(
            session.DeviceId,
            reqId,
            status,
            rev,
            threadId,
            turnId,
            approvalRequestId,
            errorCode,
            message);

        await SendEnvelopeAsync(session, "command.ack", reqId, ack, cancellationToken);
        var snap = await _backend.GetSnapshotAsync(_store.HostId, _hostName, rev, cancellationToken);
        await BroadcastSnapshotAsync(snap, cancellationToken);
    }

    private void ReassignWriterLocked()
    {
        if (_activeWriterDeviceId is not null)
        {
            return;
        }
        var candidate = _sessions.Values.FirstOrDefault(s => s.IsAuthenticated && s.DeviceId is not null);
        if (candidate?.DeviceId is not null)
        {
            _activeWriterDeviceId = candidate.DeviceId;
            _activeWriterName = candidate.DeviceName;
            foreach (var s in _sessions.Values)
            {
                s.Role = string.Equals(s.DeviceId, _activeWriterDeviceId, StringComparison.Ordinal) ? "readWrite" : "readOnly";
            }
        }
    }

    private async Task BroadcastLeaseAsync(string? requestId, CancellationToken cancellationToken)
    {
        foreach (var session in _sessions.Values.Where(s => s.IsAuthenticated))
        {
            await SendEnvelopeAsync(session, "session.lease", requestId, new
            {
                role = session.Role,
                activeWriterDeviceID = _activeWriterDeviceId,
                activeWriterName = _activeWriterName,
                canTakeover = true,
            }, cancellationToken);
        }
    }

    private async Task BroadcastSnapshotAsync(MicroRemoteSnapshotPayload snapshot, CancellationToken cancellationToken)
    {
        foreach (var session in _sessions.Values.Where(s => s.IsAuthenticated))
        {
            await SendEnvelopeAsync(session, "state.snapshot", null, snapshot, cancellationToken);
        }
    }

    private static string ComputeCanonicalPayloadHash(string type, JsonObject payload)
    {
        var fields = new List<(string Key, string Value)>();
        foreach (var key in new[] { "threadID", "model", "effort", "turnID", "approvalRequestID", "approvalContentHash", "text" })
        {
            if (payload[key]?.GetValue<string>() is { } s)
            {
                fields.Add((key, s));
            }
        }
        if (payload["enabled"]?.GetValue<bool>() is { } b)
        {
            fields.Add(("enabled", b ? "true" : "false"));
        }
        if (payload["delta"]?.GetValue<int>() is { } d)
        {
            fields.Add(("delta", d.ToString()));
        }
        return MicroRemoteCrypto.ComputeCommandPayloadHash(type, fields);
    }

    private static Task SendErrorAsync(
        ConnectedSession session,
        string? requestId,
        string code,
        string message,
        CancellationToken cancellationToken)
        => SendEnvelopeAsync(session, "error", requestId, new { code, message }, cancellationToken);

    private static async Task SendEnvelopeAsync<T>(
        ConnectedSession session,
        string type,
        string? requestId,
        T payload,
        CancellationToken cancellationToken)
    {
        if (session.WebSocket.State != WebSocketState.Open)
        {
            return;
        }
        var envelope = new
        {
            type,
            v = MicroRemoteConstants.ProtocolVersion,
            requestID = requestId,
            payload,
        };
        var bytes = JsonSerializer.SerializeToUtf8Bytes(envelope);
        await session.SendLock.WaitAsync(cancellationToken);
        try
        {
            if (session.WebSocket.State == WebSocketState.Open)
            {
                await session.WebSocket.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, cancellationToken);
            }
        }
        finally
        {
            session.SendLock.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_app is not null)
        {
            await _app.StopAsync();
            await _app.DisposeAsync();
            _app = null;
        }
        _certificate.Dispose();
    }
}
