using System.Text.Json;
using System.Text.Json.Nodes;

namespace CodexMicro.Codex;

internal static class JsonSupport
{
    internal static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    internal static JsonNode Node(object value) => JsonSerializer.SerializeToNode(value, Options)!;
    internal static string? Text(this JsonNode? node, string property) =>
        node is JsonObject obj && obj[property] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
    internal static string Required(this JsonNode node, string property) =>
        node.Text(property) is { Length: > 0 } value ? value : throw new ArgumentException($"Missing {property}");
    internal static string ThreadId(string id) => Guid.TryParse(id, out _) ? id : throw new ArgumentException("Invalid thread ID");
}
