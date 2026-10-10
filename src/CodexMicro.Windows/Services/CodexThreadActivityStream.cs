using System.Text.Json;
using System.Text.Json.Nodes;
using CodexMicro.Core.Models;

namespace CodexMicro.Desktop.Services;

internal readonly record struct CodexThreadActivity(
    ThreadStatus Status,
    bool HasPendingQuestion = false,
    string? TurnId = null,
    string? ErrorCode = null,
    bool HasCurrentTurn = false)
{
    internal static CodexThreadActivity Unknown => new(ThreadStatus.Unknown);
}

internal readonly record struct CodexThreadActivityObservation(
    string ThreadId, long Sequence, CodexThreadActivity Activity);

// Runtime status and turn lifecycle arrive independently. A resumed owner's
// latest turn is current evidence; history in a needs_resume snapshot is not.
// Retain metadata only, never the messages or tool output inside turn items.
internal sealed class CodexThreadActivityStream
{
    private JsonObject _state = new();
    internal bool IsValid { get; private set; } = true;

    internal CodexThreadActivity Current
    {
        get
        {
            if (!IsValid) return CodexThreadActivity.Unknown;
            if ((_state["threadRuntimeStatus"] is { } rawRuntime && rawRuntime is not JsonObject) ||
                (_state["requests"] is { } rawRequests && rawRequests is not JsonArray) ||
                (_state["unconfirmedTurnSubmissions"] is { } rawSubmissions && rawSubmissions is not JsonArray) ||
                (_state["turns"] is { } rawTurns && rawTurns is not JsonArray) ||
                (_state["turnHistory"] is { } rawHistory && rawHistory is not JsonObject))
                return Invalid();
            var runtime = _state["threadRuntimeStatus"] as JsonObject;
            var type = Text(runtime?["type"]);
            if (type == "systemError") return new(ThreadStatus.Error);
            if (runtime?["activeFlags"] is { } rawFlags && rawFlags is not JsonArray)
                return Invalid();
            var activity = new CodexThreadActivity(type switch
            {
                "active" => ThreadStatus.Thinking,
                "idle" => ThreadStatus.Idle,
                _ => ThreadStatus.Unknown,
            });
            var resume = Text(_state["resumeState"]);
            if (resume == "resumed")
            {
                if ((_state["unconfirmedTurnSubmissions"] as JsonArray)?.Any(submission =>
                    submission is JsonObject obj && !IsTrue(obj["terminal"])) == true)
                {
                    // The previous turn may already be complete while its
                    // successor is still awaiting admission.
                    activity = new(ThreadStatus.Thinking, HasCurrentTurn: true);
                }
                else if (LatestTurn() is { } turn)
                {
                    var status = Text(turn["status"]) switch
                    {
                        "inProgress" => ThreadStatus.Thinking,
                        "completed" or "interrupted" => ThreadStatus.Idle,
                        "failed" => ThreadStatus.Error,
                        _ => ThreadStatus.Unknown,
                    };
                    activity = new(status, TurnId: Text(turn["turnId"]),
                        ErrorCode: ErrorCode(turn["error"]), HasCurrentTurn: true);
                }
            }
            else if (resume == "resuming" && activity.Status != ThreadStatus.Thinking)
            {
                return CodexThreadActivity.Unknown;
            }
            if (activity.Status != ThreadStatus.Thinking) return activity;
            var flags = (runtime?["activeFlags"] as JsonArray)?.Select(Text).ToArray() ?? [];
            var requests = (_state["requests"] as JsonArray)?.OfType<JsonObject>()
                .Select(request => Text(request["method"])).ToArray() ?? [];
            if (flags.Contains("waitingOnApproval") || requests.Any(method => method is
                "item/commandExecution/requestApproval" or "item/fileChange/requestApproval"))
                return activity with { Status = ThreadStatus.RequiresInput };
            return activity with { HasPendingQuestion = flags.Contains("waitingOnUserInput") ||
                requests.Contains("item/tool/requestUserInput") };
        }
    }

    private CodexThreadActivity Invalid()
    {
        IsValid = false;
        return CodexThreadActivity.Unknown;
    }

    private JsonObject? LatestTurn()
    {
        if (_state["turnHistory"] is JsonObject history && Text(history["kind"]) == "canonical")
        {
            // Only the island with an exhausted newer boundary contains the
            // current end. Loading an older page must not replace that end.
            if (history["history"] is not JsonObject canonical ||
                canonical["islands"] is not JsonArray { Count: > 0 } islands ||
                islands[^1] is not JsonObject island ||
                island["newerBoundary"] is not JsonObject boundary || Text(boundary["status"]) != "exhausted" ||
                island["entries"] is not JsonArray { Count: > 0 } entries ||
                entries[^1] is not JsonObject entry || Text(entry["value"]) is not { } key ||
                canonical["entitiesByKey"] is not JsonObject entities)
                return null;
            return entities[key] as JsonObject;
        }
        return _state["turns"] is JsonArray { Count: > 0 } turns ? turns[^1] as JsonObject : null;
    }

    private static string? ErrorCode(JsonNode? error) => error is JsonObject obj
        ? Text(obj["codexErrorInfo"]) ?? Text(obj["code"]) : null;

    internal void Reset()
    {
        _state = new();
        IsValid = true;
    }

    internal void ReadState(JsonElement state)
    {
        Reset();
        _state = (JsonObject)ReadMetadata(state, [])!;
    }

    internal void ApplyPatch(string operation, string[] path, JsonElement value)
    {
        if (path.Length == 0)
        {
            if (operation == "remove" || value.ValueKind != JsonValueKind.Object) Reset();
            else ReadState(value);
            return;
        }
        if (!Retain(path) || !IsValid) return;
        try
        {
            JsonNode? parent = _state;
            foreach (var segment in path[..^1])
                parent = parent is JsonArray array ? array[int.Parse(segment)] : parent?[segment];
            var key = path[^1];
            var replacement = operation == "remove" ? null : ReadMetadata(value, path);
            if (parent is JsonObject obj)
            {
                if (operation == "remove") obj.Remove(key);
                else obj[key] = replacement;
            }
            else if (parent is JsonArray array)
            {
                if (key == "length" && value.ValueKind == JsonValueKind.Number &&
                    value.TryGetInt32(out var length) && length >= 0 && length <= array.Count)
                {
                    while (array.Count > length) array.RemoveAt(array.Count - 1);
                }
                else
                {
                    var index = key == "-" ? array.Count : int.Parse(key);
                    if (operation == "remove") array.RemoveAt(index);
                    else if (operation == "add") array.Insert(index, replacement);
                    else array[index] = replacement;
                }
            }
            else IsValid = false;
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or
            FormatException or OverflowException or JsonException)
        {
            IsValid = false;
        }
    }

    private static JsonNode? ReadMetadata(JsonElement value, string[] path)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            var result = new JsonObject();
            foreach (var property in value.EnumerateObject())
            {
                string[] child = [.. path, property.Name];
                if (Retain(child)) result[property.Name] = ReadMetadata(property.Value, child);
            }
            return result;
        }
        if (value.ValueKind == JsonValueKind.Array)
        {
            var result = new JsonArray();
            var index = 0;
            foreach (var child in value.EnumerateArray())
                result.Add(ReadMetadata(child, [.. path, (index++).ToString(System.Globalization.CultureInfo.InvariantCulture)]));
            return result;
        }
        return JsonNode.Parse(value.GetRawText());
    }

    private static bool Retain(string[] path) => path switch
    {
        ["resumeState"] => true,
        ["threadRuntimeStatus", ..] => true,
        ["requests"] or ["requests", _] or ["requests", _, "method"] => true,
        ["unconfirmedTurnSubmissions"] or ["unconfirmedTurnSubmissions", _] or
            ["unconfirmedTurnSubmissions", _, "terminal"] => true,
        ["turns"] or ["turns", _] => true,
        ["turns", _, "turnId" or "status" or "error"] or
            ["turns", _, "error", "codexErrorInfo" or "code"] => true,
        ["turnHistory"] or ["turnHistory", "kind"] or ["turnHistory", "history"] => true,
        ["turnHistory", "history", "entitiesByKey"] or ["turnHistory", "history", "entitiesByKey", _] => true,
        ["turnHistory", "history", "entitiesByKey", _, "turnId" or "status" or "error"] or
            ["turnHistory", "history", "entitiesByKey", _, "error", "codexErrorInfo" or "code"] => true,
        ["turnHistory", "history", "islands"] or ["turnHistory", "history", "islands", _] => true,
        ["turnHistory", "history", "islands", _, "newerBoundary", ..] => true,
        ["turnHistory", "history", "islands", _, "entries"] or
            ["turnHistory", "history", "islands", _, "entries", _] or
            ["turnHistory", "history", "islands", _, "entries", _, "value"] => true,
        _ => false,
    };

    private static string? Text(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static bool IsTrue(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<bool>(out var flag) && flag;
}
