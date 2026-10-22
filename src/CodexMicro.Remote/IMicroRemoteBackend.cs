using CodexMicro.Protocol;

namespace CodexMicro.Remote;

public interface IMicroRemoteBackend
{
    Task<MicroRemoteSnapshotPayload> GetSnapshotAsync(string hostId, string hostName, int revision, CancellationToken cancellationToken);
    Task<MicroRemoteThreadsListResultPayload> ListThreadsAsync(string? query, string? cursor, int limit, int revision, CancellationToken cancellationToken);
    Task<MicroRemoteThreadDetailResultPayload> ReadThreadDetailAsync(string threadId, int revision, CancellationToken cancellationToken);

    Task<MicroSendResult> SelectThreadAsync(string threadId, bool openInDesktop, CancellationToken cancellationToken);
    Task<MicroSendResult> SetModelAsync(string threadId, string model, string? effort, CancellationToken cancellationToken);
    Task<MicroSendResult> SetEffortAsync(string threadId, string effort, CancellationToken cancellationToken);
    Task<MicroSendResult> StepEffortAsync(string threadId, int delta, CancellationToken cancellationToken);
    Task<MicroSendResult> SetFastModeAsync(string threadId, bool enabled, CancellationToken cancellationToken);
    Task<MicroSendResult> SetPlanModeAsync(string threadId, bool enabled, CancellationToken cancellationToken);
    Task<MicroSendResult> ReplyApprovalAsync(string threadId, string approvalRequestId, string? approvalContentHash, bool accept, CancellationToken cancellationToken);
    Task<MicroSendResult> StopTurnAsync(string threadId, string turnId, CancellationToken cancellationToken);
    Task<MicroSendResult> SendTextAsync(string threadId, string text, CancellationToken cancellationToken);
}
