namespace CodexMicro.Control;

public sealed record BrokerDriverInfo(
    ulong ConnectionEpoch,
    ulong LastBatchSequence,
    ulong OutputSequence,
    uint DroppedOutputReports,
    uint Flags,
    string TransportName,
    bool CodexLinkObserved = false);
