using System.Buffers;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using CodexMicro.Desktop.Services;

namespace CodexMicro.Codex;

// Projects while consuming the wire frame. In particular, skipped strings can
// span any number of buffers: tool output is never made into a string or DOM.
internal sealed class CodexActivityMessageReader(Stream stream, CancellationToken cancellationToken)
{
    [Flags]
    private enum Shape : long
    {
        None = 0, Scalar = 1L << 0, Scalars = 1L << 1, Envelope = 1L << 2, Parameters = 1L << 3,
        Change = 1L << 4, Patches = 1L << 5, Patch = 1L << 6, State = 1L << 7, Runtime = 1L << 8,
        Requests = 1L << 9, Request = 1L << 10, Submissions = 1L << 11, Submission = 1L << 12,
        Turns = 1L << 13, Turn = 1L << 14, Error = 1L << 15, TurnHistory = 1L << 16,
        History = 1L << 17, Entities = 1L << 18, Islands = 1L << 19, Island = 1L << 20,
        Boundary = 1L << 21, Entries = 1L << 22, Entry = 1L << 23, Items = 1L << 24,
        Item = 1L << 25, Inputs = 1L << 26, Input = 1L << 27, Reply = 1L << 28,
    }

    // JSON object property order is not significant. A patch whose value comes
    // before its path is projected against the union of the state schemas.
    private const Shape AnyState = Shape.Scalar | Shape.Scalars | Shape.State | Shape.Runtime |
        Shape.Requests | Shape.Request | Shape.Submissions | Shape.Submission | Shape.Turns |
        Shape.Turn | Shape.Error | Shape.TurnHistory | Shape.History | Shape.Entities |
        Shape.Islands | Shape.Island | Shape.Boundary | Shape.Entries | Shape.Entry |
        Shape.Items | Shape.Item | Shape.Inputs | Shape.Input | Shape.Reply;
    private const int MaximumScalarBytes = 64 * 1024;
    private const int MaximumMetadataBytes = 8 * 1024 * 1024;
    private const int MaximumMetadataNodes = 100_000;
    private readonly byte[] _buffer = new byte[64 * 1024];
    private int _position, _count, _metadataBytes, _nodes;
    private readonly HashSet<JsonNode> _oversizedScalars = new(ReferenceEqualityComparer.Instance);
    private bool _unresolvedPatchValue;

    internal static async Task<JsonObject> ReadAsync(Stream stream, CancellationToken token)
    {
        var reader = new CodexActivityMessageReader(stream, token);
        var result = await reader.ValueAsync(Shape.Envelope, 0).ConfigureAwait(false) as JsonObject
            ?? throw new JsonException("Invalid activity message");
        await reader.WhitespaceAsync().ConfigureAwait(false);
        if (await reader.PeekAsync().ConfigureAwait(false) != -1)
            throw new JsonException("Trailing activity message data");
        return result;
    }

    private async ValueTask<JsonNode?> ValueAsync(Shape shape, int depth)
    {
        if (depth > 64) throw new JsonException("Activity message nesting is too deep");
        cancellationToken.ThrowIfCancellationRequested();
        await WhitespaceAsync().ConfigureAwait(false);
        var next = await PeekAsync().ConfigureAwait(false);
        if (shape != Shape.None && ++_nodes > MaximumMetadataNodes)
            throw new JsonException("Too many activity metadata nodes");
        if (next == '{')
        {
            ++_position;
            var result = shape == Shape.None ? null : new JsonObject();
            await WhitespaceAsync().ConfigureAwait(false);
            if (await PeekAsync().ConfigureAwait(false) == '}') { ++_position; return result; }
            var valueBeforePath = false;
            while (true)
            {
                await WhitespaceAsync().ConfigureAwait(false);
                var name = await StringAsync(shape != Shape.None).ConfigureAwait(false);
                if (shape != Shape.None && name is null) throw new JsonException("Activity property name is too long");
                await WhitespaceAsync().ConfigureAwait(false);
                await ExpectAsync(':').ConfigureAwait(false);
                var child = Child(shape, name ?? "");
                if (shape == Shape.Patch && name == "value")
                {
                    valueBeforePath = !result!.ContainsKey("path");
                    child = valueBeforePath ? AnyState : PathShape(result["path"]);
                }
                var wasUnresolved = _unresolvedPatchValue;
                _unresolvedPatchValue |= shape == Shape.Patch && name == "value" && valueBeforePath;
                var value = await ValueAsync(child, depth + 1).ConfigureAwait(false);
                _unresolvedPatchValue = wasUnresolved;
                if (child != Shape.None || (shape == Shape.Patch && name == "value"))
                {
                    Retained(name!.Length * 2);
                    result![name] = value;
                }
                await WhitespaceAsync().ConfigureAwait(false);
                next = await PeekAsync().ConfigureAwait(false);
                ++_position;
                if (next == '}') break;
                if (next != ',') throw new JsonException("Invalid activity object separator");
            }
            if (shape == Shape.Patch && valueBeforePath)
            {
                var value = result!["value"];
                var filtered = ProjectDeferredValue(value, PathShape(result["path"]));
                if (!ReferenceEquals(value, filtered)) result["value"] = filtered;
                _oversizedScalars.Clear();
            }
            return result;
        }
        if (next == '[')
        {
            ++_position;
            var result = shape == Shape.None ? null : new JsonArray();
            await WhitespaceAsync().ConfigureAwait(false);
            if (await PeekAsync().ConfigureAwait(false) == ']') { ++_position; return result; }
            while (true)
            {
                var nodesBefore = _nodes;
                var bytesBefore = _metadataBytes;
                var element = Element(shape);
                if (result is not null && element == Shape.None && ++_nodes > MaximumMetadataNodes)
                    throw new JsonException("Too many activity metadata nodes");
                var value = await ValueAsync(element, depth + 1).ConfigureAwait(false);
                if (shape == Shape.Patches && CanSkipPatch(value))
                {
                    // Unrelated patches still advance the enclosing revision,
                    // but their paths and operations need no retained storage.
                    _nodes = nodesBefore;
                    _metadataBytes = bytesBefore;
                }
                else result?.Add(value);
                await WhitespaceAsync().ConfigureAwait(false);
                next = await PeekAsync().ConfigureAwait(false);
                ++_position;
                if (next == ']') break;
                if (next != ',') throw new JsonException("Invalid activity array separator");
            }
            return result;
        }
        if (next == '"')
        {
            if (shape != Shape.None && (shape & (Shape.Scalar | Shape.Reply)) == 0)
            {
                // Preserve an incorrect JSON kind for state validation, but
                // never retain text where the schema expects a container.
                await StringAsync(false).ConfigureAwait(false);
                return JsonValue.Create("");
            }
            var value = await StringAsync(shape != Shape.None).ConfigureAwait(false);
            if (shape == Shape.None) return null;
            if ((shape & Shape.Reply) != 0 && (shape & Shape.Scalar) == 0)
            {
                if (value?.Trim() is not { } reply || !reply.StartsWith("<send_user_message_question_reply>", StringComparison.Ordinal) ||
                    !reply.EndsWith("</send_user_message_question_reply>", StringComparison.Ordinal)) return null;
                Retained(reply.Length * 2);
                return JsonValue.Create(reply);
            }
            if (value is null)
            {
                if (!_unresolvedPatchValue) throw new JsonException("Activity scalar is too long");
                var marker = new JsonObject();
                _oversizedScalars.Add(marker);
                return marker;
            }
            Retained((value?.Length ?? 0) * 2);
            return JsonValue.Create(value);
        }
        if (next == -1) throw new EndOfStreamException("Incomplete activity message");
        if (shape == Shape.None)
        {
            await SkipPrimitiveAsync().ConfigureAwait(false);
            return null;
        }
        var scalar = new ArrayBufferWriter<byte>();
        while ((next = await PeekAsync().ConfigureAwait(false)) != -1 && next is not (',' or '}' or ']' or ' ' or '\t' or '\r' or '\n'))
        {
            if (scalar.WrittenCount == MaximumScalarBytes) throw new JsonException("Invalid activity scalar");
            scalar.GetSpan(1)[0] = (byte)next;
            scalar.Advance(1);
            ++_position;
        }
        var parsed = JsonNode.Parse(scalar.WrittenSpan);
        Retained(scalar.WrittenCount);
        return parsed;
    }

    private async ValueTask SkipPrimitiveAsync()
    {
        var next = await PeekAsync().ConfigureAwait(false);
        var literal = next switch { 't' => "true", 'f' => "false", 'n' => "null", _ => null };
        if (literal is not null)
        {
            foreach (var character in literal) await ExpectAsync(character).ConfigureAwait(false);
            return;
        }
        if (next == '-') { ++_position; next = await PeekAsync().ConfigureAwait(false); }
        if (next == '0') ++_position;
        else if (next is >= '1' and <= '9') await DigitsAsync().ConfigureAwait(false);
        else throw new JsonException("Invalid activity number");
        if (await PeekAsync().ConfigureAwait(false) == '.')
        {
            ++_position;
            await DigitsAsync().ConfigureAwait(false);
        }
        if (await PeekAsync().ConfigureAwait(false) is 'e' or 'E')
        {
            ++_position;
            if (await PeekAsync().ConfigureAwait(false) is '+' or '-') ++_position;
            await DigitsAsync().ConfigureAwait(false);
        }
    }

    private async ValueTask DigitsAsync()
    {
        if (await PeekAsync().ConfigureAwait(false) is not (>= '0' and <= '9'))
            throw new JsonException("Invalid activity number");
        do { ++_position; } while (await PeekAsync().ConfigureAwait(false) is >= '0' and <= '9');
    }

    private async ValueTask<string?> StringAsync(bool retain)
    {
        await ExpectAsync('"').ConfigureAwait(false);
        var bytes = retain ? new ArrayBufferWriter<byte>() : null;
        var escaped = false;
        var unicode = 0;
        while (true)
        {
            if (await PeekAsync().ConfigureAwait(false) == -1) throw new EndOfStreamException("Incomplete activity string");
            var start = _position;
            var closed = false;
            while (_position < _count)
            {
                var b = _buffer[_position++];
                if (unicode > 0)
                {
                    if (b is not (>= (byte)'0' and <= (byte)'9' or >= (byte)'a' and <= (byte)'f' or >= (byte)'A' and <= (byte)'F'))
                        throw new JsonException("Invalid activity string escape");
                    --unicode;
                }
                else if (escaped)
                {
                    escaped = false;
                    if (b == 'u') unicode = 4;
                    else if (b is not ((byte)'"' or (byte)'\\' or (byte)'/' or (byte)'b' or (byte)'f' or (byte)'n' or (byte)'r' or (byte)'t'))
                        throw new JsonException("Invalid activity string escape");
                }
                else if (b == '"') { closed = true; break; }
                else if (b == '\\') escaped = true;
                else if (b < 0x20) throw new JsonException("Invalid activity string character");
            }
            var length = _position - start - (closed ? 1 : 0);
            if (bytes is not null)
            {
                if (bytes.WrittenCount + length > MaximumScalarBytes) bytes = null;
                else bytes.Write(_buffer.AsSpan(start, length));
            }
            if (!closed) continue;
            if (bytes is null) return null;
            // Decode only retained, bounded tokens with the standard JSON parser.
            var quoted = new byte[bytes.WrittenCount + 2];
            quoted[0] = quoted[^1] = (byte)'"';
            bytes.WrittenSpan.CopyTo(quoted.AsSpan(1));
            return JsonSerializer.Deserialize<string>(quoted);
        }
    }

    private void Retained(int bytes)
    {
        _metadataBytes += bytes;
        if (_metadataBytes > MaximumMetadataBytes) throw new JsonException("Activity metadata is too large");
    }

    private JsonNode? ProjectDeferredValue(JsonNode? value, Shape shape)
    {
        if (shape == Shape.None || value is null) return null;
        if (_oversizedScalars.Contains(value))
        {
            if (shape == Shape.Reply) return null;
            throw new JsonException("Activity patch metadata is too large");
        }
        if (value is JsonObject obj)
        {
            foreach (var (name, child) in obj.ToArray())
            {
                var childShape = Child(shape, name);
                if (childShape == Shape.None) obj.Remove(name);
                else
                {
                    var filtered = ProjectDeferredValue(child, childShape);
                    if (!ReferenceEquals(child, filtered)) obj[name] = filtered;
                }
            }
        }
        else if (value is JsonArray array)
        {
            var element = Element(shape);
            if (element == Shape.None) array.Clear();
            else for (var index = 0; index < array.Count; ++index)
            {
                var filtered = ProjectDeferredValue(array[index], element);
                if (!ReferenceEquals(array[index], filtered)) array[index] = filtered;
            }
        }
        else if (shape == Shape.Reply && value is JsonValue scalar && scalar.TryGetValue<string>(out var text))
        {
            var reply = text.Trim();
            if (!reply.StartsWith("<send_user_message_question_reply>", StringComparison.Ordinal) ||
                !reply.EndsWith("</send_user_message_question_reply>", StringComparison.Ordinal)) return null;
        }
        return value;
    }

    private async ValueTask<int> PeekAsync()
    {
        if (_position < _count) return _buffer[_position];
        _count = await stream.ReadAsync(_buffer, cancellationToken).ConfigureAwait(false);
        _position = 0;
        return _count == 0 ? -1 : _buffer[0];
    }

    private async ValueTask WhitespaceAsync()
    {
        while (await PeekAsync().ConfigureAwait(false) is ' ' or '\t' or '\r' or '\n') ++_position;
    }

    private async ValueTask ExpectAsync(int expected)
    {
        if (await PeekAsync().ConfigureAwait(false) != expected) throw new JsonException("Invalid activity JSON token");
        ++_position;
    }

    private static Shape PathShape(JsonNode? path)
    {
        string[] parts;
        if (path is JsonArray array)
            parts = array.Select(value => value is JsonValue scalar && scalar.TryGetValue<string>(out var text)
                ? text : value?.ToJsonString() ?? "").ToArray();
        else if (path is JsonValue scalar && scalar.TryGetValue<string>(out var text))
        {
            if (text.Length == 0) return Shape.State;
            if (!text.StartsWith('/')) return Shape.None;
            parts = text[1..].Split('/').Select(part => part.Replace("~1", "/", StringComparison.Ordinal)
                .Replace("~0", "~", StringComparison.Ordinal)).ToArray();
        }
        else return Shape.None;
        var shape = Shape.State;
        foreach (var part in parts)
        {
            var element = Element(shape);
            // Keep malformed indices and descendants of scalar fields for the
            // activity accumulator to reject; filtering must not hide them.
            shape = Child(shape, part) | (element != Shape.None
                ? part == "length" ? Shape.Scalar : element
                : shape & (Shape.Scalar | Shape.Reply));
        }
        return shape;
    }

    private static bool CanSkipPatch(JsonNode? value)
    {
        if (value is not JsonObject patch || PathShape(patch["path"]) != Shape.None) return false;
        using var document = JsonSerializer.SerializeToDocument(patch);
        var root = document.RootElement;
        // Preserve malformed operations so the observer withdraws its evidence
        // instead of accepting a revision with an unvalidated patch.
        return root.TryGetProperty("op", out var operation) && operation.ValueKind == JsonValueKind.String &&
            operation.GetString() is "add" or "replace" or "remove" &&
            CodexThreadModelStateAccumulator.TryReadPatchPath(root, out _) &&
            (operation.GetString() == "remove" || root.TryGetProperty("value", out _));
    }

    private static Shape Element(Shape shape)
    {
        var result = Shape.None;
        if ((shape & Shape.Scalars) != 0) result |= Shape.Scalar;
        if ((shape & Shape.Patches) != 0) result |= Shape.Patch;
        if ((shape & Shape.Requests) != 0) result |= Shape.Request;
        if ((shape & Shape.Submissions) != 0) result |= Shape.Submission;
        if ((shape & Shape.Turns) != 0) result |= Shape.Turn;
        if ((shape & Shape.Islands) != 0) result |= Shape.Island;
        if ((shape & Shape.Entries) != 0) result |= Shape.Entry;
        if ((shape & Shape.Items) != 0) result |= Shape.Item;
        if ((shape & Shape.Inputs) != 0) result |= Shape.Input;
        return result;
    }

    private static Shape Child(Shape shape, string name)
    {
        var result = Shape.None;
        if ((shape & Shape.Envelope) != 0) result |= name switch
        {
            "type" or "method" or "version" or "requestId" or "resultType" or "sourceClientId" or "handledByClientId" or "error" => Shape.Scalar,
            "params" => Shape.Parameters, "result" => Shape.Parameters, _ => Shape.None,
        };
        if ((shape & Shape.Parameters) != 0) result |= name switch
        {
            "hostId" or "conversationId" or "clientId" or "status" => Shape.Scalar,
            "change" => Shape.Change, _ => Shape.None,
        };
        if ((shape & Shape.Change) != 0) result |= name switch
        {
            "type" or "revision" or "baseRevision" => Shape.Scalar,
            "conversationState" => Shape.State, "patches" => Shape.Patches, _ => Shape.None,
        };
        if ((shape & Shape.Patch) != 0) result |= name switch
        { "op" => Shape.Scalar, "path" => Shape.Scalar | Shape.Scalars, _ => Shape.None };
        if ((shape & Shape.State) != 0) result |= name switch
        {
            "resumeState" => Shape.Scalar, "threadRuntimeStatus" => Shape.Runtime,
            "requests" => Shape.Requests, "unconfirmedTurnSubmissions" => Shape.Submissions,
            "turns" => Shape.Turns, "turnHistory" => Shape.TurnHistory, _ => Shape.None,
        };
        if ((shape & Shape.Runtime) != 0) result |= name switch
        { "type" => Shape.Scalar, "activeFlags" => Shape.Scalars, _ => Shape.None };
        if ((shape & Shape.Request) != 0 && name == "method") result |= Shape.Scalar;
        if ((shape & Shape.Submission) != 0 && name == "terminal") result |= Shape.Scalar;
        if ((shape & Shape.Turn) != 0) result |= name switch
        { "turnId" or "status" => Shape.Scalar, "error" => Shape.Error, "items" => Shape.Items, _ => Shape.None };
        if ((shape & Shape.Error) != 0 && name is "code" or "codexErrorInfo") result |= Shape.Scalar;
        if ((shape & Shape.TurnHistory) != 0) result |= name switch
        { "kind" => Shape.Scalar, "history" => Shape.History, _ => Shape.None };
        if ((shape & Shape.History) != 0) result |= name switch
        { "entitiesByKey" => Shape.Entities, "islands" => Shape.Islands, _ => Shape.None };
        if ((shape & Shape.Entities) != 0) result |= Shape.Turn;
        if ((shape & Shape.Island) != 0) result |= name switch
        { "newerBoundary" => Shape.Boundary, "entries" => Shape.Entries, _ => Shape.None };
        if ((shape & Shape.Boundary) != 0 && name == "status") result |= Shape.Scalar;
        if ((shape & Shape.Entry) != 0 && name == "value") result |= Shape.Scalar;
        if ((shape & Shape.Item) != 0) result |= name switch
        { "type" or "status" => Shape.Scalar, "content" or "input" => Shape.Inputs, _ => Shape.None };
        if ((shape & Shape.Input) != 0) result |= name switch
        { "type" => Shape.Scalar, "text" => Shape.Reply, _ => Shape.None };
        return result;
    }
}
