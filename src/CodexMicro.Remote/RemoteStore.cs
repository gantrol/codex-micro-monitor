using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace CodexMicro.Remote;

public sealed record PairedDeviceRecord(
    string DeviceId,
    string DeviceName,
    string Platform,
    string TokenHash,
    string? DevicePublicKey,
    long PairedAtMs,
    long LastSeenAtMs,
    bool IsRevoked);

public sealed record PairingTokenRecord(
    string TokenHash,
    long ExpiresAtMs,
    bool Consumed);

public sealed record LedgerRecord(
    string DeviceId,
    string RequestId,
    string PayloadHash,
    string CommandType,
    string Status,
    int Revision,
    string? ThreadId,
    string? TurnId,
    string? ApprovalRequestId,
    string? ErrorCode,
    string? Message,
    long CreatedAtMs,
    long UpdatedAtMs)
{
    public MicroRemoteCommandAckPayload ToAckPayload() => new(
        CommandType: CommandType,
        Status: Status,
        Revision: Revision,
        ThreadID: ThreadId,
        TurnID: TurnId,
        ApprovalRequestID: ApprovalRequestId,
        ErrorCode: ErrorCode,
        Message: Message);
}

public enum LedgerBeginOutcomeKind
{
    Started,
    Existing,
    PayloadConflict,
}

public readonly record struct LedgerBeginOutcome(
    LedgerBeginOutcomeKind Kind,
    MicroRemoteCommandAckPayload? ExistingAck);

public sealed class RemotePersistentStore
{
    private sealed class PersistedState
    {
        public string HostId { get; set; } = string.Empty;
        public string HostPrivateKeyBase64 { get; set; } = string.Empty;
        public string HostPublicKeyBase64 { get; set; } = string.Empty;
        public Dictionary<string, PairingTokenRecord> PairingTokens { get; set; } = new(StringComparer.Ordinal);
        public Dictionary<string, PairedDeviceRecord> PairedDevices { get; set; } = new(StringComparer.Ordinal);
        public Dictionary<string, LedgerRecord> CommandLedger { get; set; } = new(StringComparer.Ordinal);
    }

    private readonly Lock _sync = new();
    private readonly string _stateFilePath;
    private readonly PersistedState _state;

    public string HostId => _state.HostId;
    public string HostPublicKeyBase64 => _state.HostPublicKeyBase64;
    public string HostPrivateKeyBase64 => _state.HostPrivateKeyBase64;

    public RemotePersistentStore(string storageDirectory)
    {
        Directory.CreateDirectory(storageDirectory);
        _stateFilePath = Path.Combine(storageDirectory, "remote-store-v2.json");
        _state = LoadAndRecover(_stateFilePath);
        FlushLocked();
    }

    public (string Token, long ExpiresAtMs) IssuePairingToken(int ttlSeconds = 300)
    {
        lock (_sync)
        {
            var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var expiredKeys = _state.PairingTokens
                .Where(kv => kv.Value.Consumed || kv.Value.ExpiresAtMs < nowMs)
                .Select(kv => kv.Key)
                .ToList();
            foreach (var k in expiredKeys)
            {
                _state.PairingTokens.Remove(k);
            }

            var rawToken = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(24));
            var hash = MicroRemoteCrypto.Sha256Hex(rawToken);
            var expiresAtMs = nowMs + (ttlSeconds * 1000L);
            _state.PairingTokens[hash] = new PairingTokenRecord(hash, expiresAtMs, Consumed: false);
            FlushLocked();
            return (rawToken, expiresAtMs);
        }
    }

    public string? ExchangePairingToken(
        string rawPairingToken,
        string deviceId,
        string deviceName,
        string platform,
        string? devicePublicKey)
    {
        lock (_sync)
        {
            var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var pairingHash = MicroRemoteCrypto.Sha256Hex(rawPairingToken);
            if (!_state.PairingTokens.TryGetValue(pairingHash, out var tokenRecord) ||
                tokenRecord.Consumed ||
                tokenRecord.ExpiresAtMs < nowMs)
            {
                return null;
            }

            _state.PairingTokens[pairingHash] = tokenRecord with { Consumed = true };

            var deviceToken = "dt_" + Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
            var deviceTokenHash = MicroRemoteCrypto.Sha256Hex(deviceToken);
            _state.PairedDevices[deviceId] = new PairedDeviceRecord(
                DeviceId: deviceId,
                DeviceName: deviceName,
                Platform: platform,
                TokenHash: deviceTokenHash,
                DevicePublicKey: devicePublicKey,
                PairedAtMs: nowMs,
                LastSeenAtMs: nowMs,
                IsRevoked: false);

            FlushLocked();
            return deviceToken;
        }
    }

    public PairedDeviceRecord? AuthenticateDevice(string deviceId, string rawDeviceToken)
    {
        lock (_sync)
        {
            var tokenHash = MicroRemoteCrypto.Sha256Hex(rawDeviceToken);
            if (!_state.PairedDevices.TryGetValue(deviceId, out var record) ||
                record.IsRevoked ||
                !string.Equals(record.TokenHash, tokenHash, StringComparison.Ordinal))
            {
                return null;
            }

            var updated = record with { LastSeenAtMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() };
            _state.PairedDevices[deviceId] = updated;
            FlushLocked();
            return updated;
        }
    }

    public IReadOnlyList<PairedDeviceRecord> ListPairedDevices()
    {
        lock (_sync)
        {
            return _state.PairedDevices.Values
                .Where(d => !d.IsRevoked)
                .OrderByDescending(d => d.LastSeenAtMs)
                .ToList();
        }
    }

    public void RevokeDevice(string deviceId)
    {
        lock (_sync)
        {
            if (_state.PairedDevices.TryGetValue(deviceId, out var existing))
            {
                _state.PairedDevices[deviceId] = existing with { IsRevoked = true };
                FlushLocked();
            }
        }
    }

    public LedgerBeginOutcome BeginOrReuseCommand(
        string deviceId,
        string requestId,
        string payloadHash,
        string commandType,
        int revision,
        string? threadId = null,
        string? turnId = null,
        string? approvalRequestId = null)
    {
        lock (_sync)
        {
            var key = $"{deviceId}|{requestId}";
            if (_state.CommandLedger.TryGetValue(key, out var existing))
            {
                if (!string.Equals(existing.PayloadHash, payloadHash, StringComparison.Ordinal))
                {
                    return new LedgerBeginOutcome(LedgerBeginOutcomeKind.PayloadConflict, null);
                }
                return new LedgerBeginOutcome(LedgerBeginOutcomeKind.Existing, existing.ToAckPayload());
            }

            var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var record = new LedgerRecord(
                DeviceId: deviceId,
                RequestId: requestId,
                PayloadHash: payloadHash,
                CommandType: commandType,
                Status: "in_progress",
                Revision: revision,
                ThreadId: threadId,
                TurnId: turnId,
                ApprovalRequestId: approvalRequestId,
                ErrorCode: null,
                Message: null,
                CreatedAtMs: nowMs,
                UpdatedAtMs: nowMs);

            _state.CommandLedger[key] = record;
            FlushLocked();
            return new LedgerBeginOutcome(LedgerBeginOutcomeKind.Started, null);
        }
    }

    public MicroRemoteCommandAckPayload CompleteCommand(
        string deviceId,
        string requestId,
        string status,
        int revision,
        string? threadId = null,
        string? turnId = null,
        string? approvalRequestId = null,
        string? errorCode = null,
        string? message = null)
    {
        lock (_sync)
        {
            var key = $"{deviceId}|{requestId}";
            var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            if (_state.CommandLedger.TryGetValue(key, out var existing))
            {
                var updated = existing with
                {
                    Status = status,
                    Revision = revision,
                    ThreadId = threadId ?? existing.ThreadId,
                    TurnId = turnId ?? existing.TurnId,
                    ApprovalRequestId = approvalRequestId ?? existing.ApprovalRequestId,
                    ErrorCode = errorCode,
                    Message = message,
                    UpdatedAtMs = nowMs,
                };
                _state.CommandLedger[key] = updated;
                FlushLocked();
                return updated.ToAckPayload();
            }

            var fallback = new LedgerRecord(
                DeviceId: deviceId,
                RequestId: requestId,
                PayloadHash: string.Empty,
                CommandType: "unknown",
                Status: status,
                Revision: revision,
                ThreadId: threadId,
                TurnId: turnId,
                ApprovalRequestId: approvalRequestId,
                ErrorCode: errorCode,
                Message: message,
                CreatedAtMs: nowMs,
                UpdatedAtMs: nowMs);
            _state.CommandLedger[key] = fallback;
            FlushLocked();
            return fallback.ToAckPayload();
        }
    }

    public MicroRemoteCommandAckPayload? QueryCommand(string deviceId, string requestId)
    {
        lock (_sync)
        {
            var key = $"{deviceId}|{requestId}";
            return _state.CommandLedger.TryGetValue(key, out var existing)
                ? existing.ToAckPayload()
                : null;
        }
    }

    private static PersistedState LoadAndRecover(string path)
    {
        PersistedState? state = null;
        if (File.Exists(path))
        {
            try
            {
                var json = File.ReadAllText(path, Encoding.UTF8);
                state = JsonSerializer.Deserialize<PersistedState>(json);
            }
            catch
            {
                state = null;
            }
        }

        state ??= new PersistedState();
        if (string.IsNullOrWhiteSpace(state.HostId))
        {
            state.HostId = "host-" + Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(6));
        }
        if (string.IsNullOrWhiteSpace(state.HostPrivateKeyBase64) ||
            string.IsNullOrWhiteSpace(state.HostPublicKeyBase64))
        {
            state.HostPrivateKeyBase64 = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
            state.HostPublicKeyBase64 = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
        }

        var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        foreach (var (key, rec) in state.CommandLedger.ToList())
        {
            if (string.Equals(rec.Status, "in_progress", StringComparison.Ordinal))
            {
                state.CommandLedger[key] = rec with
                {
                    Status = "unknown",
                    ErrorCode = "host_restarted_during_execution",
                    Message = "Host restarted while command was in progress.",
                    UpdatedAtMs = nowMs,
                };
            }
        }
        return state;
    }

    private void FlushLocked()
    {
        var tmpPath = _stateFilePath + ".tmp";
        var bytes = JsonSerializer.SerializeToUtf8Bytes(_state);
        using (var fs = new FileStream(tmpPath, FileMode.Create, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
        {
            fs.Write(bytes, 0, bytes.Length);
            fs.Flush(flushToDisk: true);
        }
        File.Move(tmpPath, _stateFilePath, overwrite: true);
    }
}
