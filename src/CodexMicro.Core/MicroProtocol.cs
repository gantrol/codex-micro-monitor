namespace CodexMicro.Protocol;

public enum MicroSendDisposition
{
    NotSent,
    Accepted,
    OutcomeUnknown,
    Rejected,
}

public readonly record struct MicroSendResult(
    MicroSendDisposition Disposition,
    int AcceptedReports,
    int RequestedReports,
    int NativeStatus,
    string Detail)
{
    public bool WasPossiblySent =>
        Disposition is MicroSendDisposition.Accepted or
            MicroSendDisposition.OutcomeUnknown;

    public static MicroSendResult NotSent(string detail) => new(
        MicroSendDisposition.NotSent,
        0,
        0,
        0,
        detail);
}

public sealed record SlotLighting(
    int SlotId,
    int Color,
    double Brightness,
    int Effect,
    double Speed,
    bool SyncKeysLighting,
    bool SyncAmbientLighting,
    bool LightingAmbiguous);

public sealed record SlotLightingSnapshot(
    long Sequence,
    DateTimeOffset ObservedAt,
    IReadOnlyList<SlotLighting> Slots,
    string MappingKind = "SlotOnly");
