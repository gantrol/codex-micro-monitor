using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexMicro.Remote;

public static class MicroRemoteConstants
{
    public const int ProtocolVersion = 2;
    public const int MinSupportedVersion = 1;
    public const int DefaultPort = 48720;
    public const string DefaultWebSocketPath = "/ws/micro";
    public const string RelayInfoString = "codex-micro-relay-v2";
}

public static class MicroRemoteCrypto
{
    public static string Sha256Hex(ReadOnlySpan<byte> bytes)
    {
        Span<byte> digest = stackalloc byte[32];
        SHA256.HashData(bytes, digest);
        return Convert.ToHexStringLower(digest);
    }

    public static string Sha256Hex(string text)
        => Sha256Hex(Encoding.UTF8.GetBytes(text));

    public static string ComputeApprovalContentHash(
        string requestId,
        string kind,
        string? commandText,
        string? cwd,
        IReadOnlyList<string>? filePaths)
    {
        var sortedPaths = filePaths is null || filePaths.Count == 0
            ? string.Empty
            : string.Join("\n", filePaths.OrderBy(p => p, StringComparer.Ordinal));
        var canonical = string.Join(
            "|",
            requestId,
            kind,
            commandText ?? string.Empty,
            cwd ?? string.Empty,
            sortedPaths);
        return Sha256Hex(canonical);
    }

    public static string ComputeCommandPayloadHash(string type, IEnumerable<(string Key, string Value)> fields)
    {
        var sorted = fields.OrderBy(f => f.Key, StringComparer.Ordinal);
        var sb = new StringBuilder(type);
        foreach (var (key, value) in sorted)
        {
            sb.Append('&').Append(key).Append('=').Append(value);
        }
        return Sha256Hex(sb.ToString());
    }
}

public sealed record MicroRemotePairPayload(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("mode")] string Mode,
    [property: JsonPropertyName("hostID")] string HostID,
    [property: JsonPropertyName("hostName")] string HostName,
    [property: JsonPropertyName("platform")] string Platform,
    [property: JsonPropertyName("endpoints")] IReadOnlyList<string> Endpoints,
    [property: JsonPropertyName("relayURL")] string? RelayURL,
    [property: JsonPropertyName("certPinSHA256")] string? CertPinSHA256,
    [property: JsonPropertyName("hostPublicKey")] string? HostPublicKey,
    [property: JsonPropertyName("pairingToken")] string PairingToken,
    [property: JsonPropertyName("expiresAtMs")] long ExpiresAtMs)
{
    public string ToUriString()
    {
        var query = new List<string>
        {
            $"v={Version}",
            $"mode={Uri.EscapeDataString(Mode)}",
            $"hostId={Uri.EscapeDataString(HostID)}",
            $"name={Uri.EscapeDataString(HostName)}",
            $"platform={Uri.EscapeDataString(Platform)}",
            $"token={Uri.EscapeDataString(PairingToken)}",
            $"exp={ExpiresAtMs}",
        };
        foreach (var ep in Endpoints.Where(e => !string.IsNullOrWhiteSpace(e)))
        {
            query.Add($"ep={Uri.EscapeDataString(ep)}");
        }
        if (!string.IsNullOrWhiteSpace(RelayURL))
        {
            query.Add($"relay={Uri.EscapeDataString(RelayURL)}");
        }
        if (!string.IsNullOrWhiteSpace(CertPinSHA256))
        {
            query.Add($"pin={Uri.EscapeDataString(CertPinSHA256)}");
        }
        if (!string.IsNullOrWhiteSpace(HostPublicKey))
        {
            query.Add($"pub={Uri.EscapeDataString(HostPublicKey)}");
        }
        return $"codexmicro://pair?{string.Join("&", query)}";
    }
}

public sealed record MicroRelayEnvelope(
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("v")] int V,
    [property: JsonPropertyName("sessionID")] string SessionID,
    [property: JsonPropertyName("hostID")] string HostID,
    [property: JsonPropertyName("deviceID")] string DeviceID,
    [property: JsonPropertyName("senderPublicKey")] string SenderPublicKey,
    [property: JsonPropertyName("seq")] ulong Seq,
    [property: JsonPropertyName("nonce")] string Nonce,
    [property: JsonPropertyName("ciphertext")] string Ciphertext);

public sealed record MicroRemotePendingApprovalDTO(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("summary")] string Summary,
    [property: JsonPropertyName("commandText")] string? CommandText,
    [property: JsonPropertyName("cwd")] string? Cwd,
    [property: JsonPropertyName("filePaths")] IReadOnlyList<string> FilePaths,
    [property: JsonPropertyName("approvalContentHash")] string ApprovalContentHash,
    [property: JsonPropertyName("createdAtMs")] long CreatedAtMs);

public sealed record MicroRemotePendingQuestionDTO(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("prompt")] string Prompt,
    [property: JsonPropertyName("options")] IReadOnlyList<string> Options);

public sealed record MicroRemoteLatestReplyDTO(
    [property: JsonPropertyName("turnID")] string? TurnID,
    [property: JsonPropertyName("text")] string Text,
    [property: JsonPropertyName("updatedAtMs")] long UpdatedAtMs,
    [property: JsonPropertyName("isStreaming")] bool IsStreaming);

public sealed record MicroRemoteThreadDTO(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("slotIndex")] int? SlotIndex,
    [property: JsonPropertyName("title")] string Title,
    [property: JsonPropertyName("workspaceName")] string WorkspaceName,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("activeTurnID")] string? ActiveTurnID,
    [property: JsonPropertyName("hasDraft")] bool HasDraft,
    [property: JsonPropertyName("hasUnreadCompletion")] bool HasUnreadCompletion,
    [property: JsonPropertyName("pendingApprovalCount")] int PendingApprovalCount,
    [property: JsonPropertyName("pendingQuestionCount")] int PendingQuestionCount,
    [property: JsonPropertyName("updatedAtMs")] long UpdatedAtMs,
    [property: JsonPropertyName("model")] string? Model,
    [property: JsonPropertyName("effort")] string? Effort,
    [property: JsonPropertyName("fastMode")] bool? FastMode,
    [property: JsonPropertyName("planMode")] bool? PlanMode,
    [property: JsonPropertyName("pendingApproval")] MicroRemotePendingApprovalDTO? PendingApproval);

public sealed record MicroRemoteQuotaWindowDTO(
    [property: JsonPropertyName("remainingRatio")] double? RemainingRatio,
    [property: JsonPropertyName("resetProgressRatio")] double? ResetProgressRatio,
    [property: JsonPropertyName("resetAtMs")] long? ResetAtMs);

public sealed record MicroRemoteQuotaDTO(
    [property: JsonPropertyName("fiveHour")] MicroRemoteQuotaWindowDTO FiveHour,
    [property: JsonPropertyName("sevenDay")] MicroRemoteQuotaWindowDTO SevenDay,
    [property: JsonPropertyName("updatedAtMs")] long? UpdatedAtMs);

public sealed record MicroRemoteModelCatalogDTO(
    [property: JsonPropertyName("models")] IReadOnlyList<string> Models,
    [property: JsonPropertyName("effortsByModel")] IReadOnlyDictionary<string, IReadOnlyList<string>> EffortsByModel);

public sealed record MicroRemoteSnapshotPayload(
    [property: JsonPropertyName("revision")] int Revision,
    [property: JsonPropertyName("hostID")] string HostID,
    [property: JsonPropertyName("hostName")] string HostName,
    [property: JsonPropertyName("hostPlatform")] string HostPlatform,
    [property: JsonPropertyName("snapshotUpdatedAtMs")] long SnapshotUpdatedAtMs,
    [property: JsonPropertyName("keypadSlotCount")] int KeypadSlotCount,
    [property: JsonPropertyName("selectedThreadID")] string? SelectedThreadID,
    [property: JsonPropertyName("model")] string? Model,
    [property: JsonPropertyName("effort")] string? Effort,
    [property: JsonPropertyName("fastMode")] bool? FastMode,
    [property: JsonPropertyName("planMode")] bool? PlanMode,
    [property: JsonPropertyName("modelCatalog")] MicroRemoteModelCatalogDTO ModelCatalog,
    [property: JsonPropertyName("quota")] MicroRemoteQuotaDTO Quota,
    [property: JsonPropertyName("threads")] IReadOnlyList<MicroRemoteThreadDTO> Threads,
    [property: JsonPropertyName("totalThreadCount")] int TotalThreadCount);

public sealed record MicroRemoteThreadDetailResultPayload(
    [property: JsonPropertyName("threadID")] string ThreadID,
    [property: JsonPropertyName("revision")] int Revision,
    [property: JsonPropertyName("activeTurnID")] string? ActiveTurnID,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("canSubmitText")] bool CanSubmitText,
    [property: JsonPropertyName("latestReply")] MicroRemoteLatestReplyDTO? LatestReply,
    [property: JsonPropertyName("approvals")] IReadOnlyList<MicroRemotePendingApprovalDTO> Approvals,
    [property: JsonPropertyName("pendingQuestions")] IReadOnlyList<MicroRemotePendingQuestionDTO> PendingQuestions);

public sealed record MicroRemoteThreadsListResultPayload(
    [property: JsonPropertyName("revision")] int Revision,
    [property: JsonPropertyName("threads")] IReadOnlyList<MicroRemoteThreadDTO> Threads,
    [property: JsonPropertyName("nextCursor")] string? NextCursor,
    [property: JsonPropertyName("totalCount")] int TotalCount);

public sealed record MicroRemoteCommandAckPayload(
    [property: JsonPropertyName("commandType")] string CommandType,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("revision")] int Revision,
    [property: JsonPropertyName("threadID")] string? ThreadID = null,
    [property: JsonPropertyName("turnID")] string? TurnID = null,
    [property: JsonPropertyName("approvalRequestID")] string? ApprovalRequestID = null,
    [property: JsonPropertyName("errorCode")] string? ErrorCode = null,
    [property: JsonPropertyName("message")] string? Message = null);
