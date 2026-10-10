using System.Text.Json;

namespace CodexMicro.Desktop.Services;

internal enum CodexComposerDraftState
{
    Unknown,
    Empty,
    Present,
}

// Reads only the persisted composer record, never submitted prompt history or
// retained editor documents (which can intentionally outlive a submitted draft).
internal static class CodexComposerDraftReader
{
    internal static IReadOnlyDictionary<string, CodexComposerDraftState> Read(
        string? globalState, IEnumerable<string> threadIds)
    {
        var states = new Dictionary<string, CodexComposerDraftState>(StringComparer.Ordinal);
        if (string.IsNullOrWhiteSpace(globalState)) return states;
        try
        {
            using var document = JsonDocument.Parse(globalState);
            if (!TryObject(document.RootElement, "electron-persisted-atom-state", out var atoms)) return states;
            // The renderer prefers v2 as a whole; an absent v2 entry must not
            // resurrect a legacy v1 draft that was already sent or cleared.
            var hasDrafts = atoms.TryGetProperty("composer-prompt-drafts-v2", out var drafts) ||
                atoms.TryGetProperty("composer-prompt-drafts-v1", out drafts);
            if (hasDrafts && drafts.ValueKind != JsonValueKind.Object) return states;
            foreach (var threadId in threadIds.Distinct(StringComparer.Ordinal))
            {
                if (!Guid.TryParse(threadId, out _)) continue;
                var key = "local:" + threadId;
                var state = hasDrafts && drafts.TryGetProperty(key, out var draft)
                    ? ReadDraft(draft) : CodexComposerDraftState.Empty;
                // These explicit user attachments are persisted separately.
                foreach (var attachmentKey in AttachmentKeys)
                {
                    if (!atoms.TryGetProperty(attachmentKey, out var entries)) continue;
                    if (entries.ValueKind != JsonValueKind.Object)
                    {
                        state = Combine(state, CodexComposerDraftState.Unknown);
                        continue;
                    }
                    if (entries.TryGetProperty(key, out var attachments))
                        state = Combine(state, ReadAttachments(attachments, attachmentKey));
                }
                states[threadId] = state;
            }
        }
        catch (JsonException)
        {
            // A partial write or unsupported document cannot assert emptiness.
            states.Clear();
        }
        return states;
    }

    private static readonly string[] AttachmentKeys =
    [
        "composer-pull-request-attachment-drafts-v1",
        "composer-response-annotation-drafts-v1",
        "composer-presentation-suggestion-drafts-v1",
    ];

    private static CodexComposerDraftState ReadDraft(JsonElement draft)
    {
        if (draft.ValueKind == JsonValueKind.Null) return CodexComposerDraftState.Empty;
        if (draft.ValueKind == JsonValueKind.String) return ReadText(draft.GetString());
        if (draft.ValueKind != JsonValueKind.Object) return CodexComposerDraftState.Unknown;
        if (draft.TryGetProperty("draft", out var wrapped)) return ReadDraft(wrapped);
        var prompt = draft.TryGetProperty("prompt", out var value) ? value : draft;
        if (prompt.ValueKind == JsonValueKind.String) return ReadText(prompt.GetString());
        return TryObject(prompt, "document", out var document)
            ? ReadNode(document) : CodexComposerDraftState.Unknown;
    }

    private static CodexComposerDraftState ReadNode(JsonElement node)
    {
        if (node.ValueKind != JsonValueKind.Object || !node.TryGetProperty("type", out var type) ||
            type.ValueKind != JsonValueKind.String) return CodexComposerDraftState.Unknown;
        var name = type.GetString();
        if (name == "text")
            return node.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String
                ? ReadText(text.GetString()) : CodexComposerDraftState.Unknown;
        // These are content-bearing inline nodes in the supported composer
        // schema. Their labels need not appear as ordinary text children.
        if (name is "atMention" or "skillMention" or "agentMention" or "appMention" or
            "pluginMention" or "browserSkillMention" or "browserTabMention" or "richLink" or
            "pageReferenceMention" or "pageTaskMention" or "resourceMention" or "image" or "horizontal_rule")
            return CodexComposerDraftState.Present;
        if (name is not ("doc" or "paragraph" or "heading" or "blockquote" or "bullet_list" or
            "ordered_list" or "list_item" or "code_block" or "hard_break"))
            return CodexComposerDraftState.Unknown;
        if (!node.TryGetProperty("content", out var content)) return CodexComposerDraftState.Empty;
        if (content.ValueKind != JsonValueKind.Array) return CodexComposerDraftState.Unknown;
        var state = CodexComposerDraftState.Empty;
        foreach (var child in content.EnumerateArray()) state = Combine(state, ReadNode(child));
        return state;
    }

    private static CodexComposerDraftState ReadText(string? text) =>
        text?.Any(character => !char.IsWhiteSpace(character) && character is not ('\u200B' or '\uFEFF')) == true
            ? CodexComposerDraftState.Present : CodexComposerDraftState.Empty;

    private static CodexComposerDraftState ReadAttachments(JsonElement attachments, string key)
    {
        if (attachments.ValueKind != JsonValueKind.Array) return CodexComposerDraftState.Unknown;
        if (key != "composer-presentation-suggestion-drafts-v1")
            return attachments.GetArrayLength() > 0 ? CodexComposerDraftState.Present : CodexComposerDraftState.Empty;
        return attachments.EnumerateArray().Any(item => item.ValueKind == JsonValueKind.Object &&
            item.TryGetProperty("isAttached", out var attached) && attached.ValueKind == JsonValueKind.True)
                ? CodexComposerDraftState.Present : CodexComposerDraftState.Empty;
    }

    private static CodexComposerDraftState Combine(CodexComposerDraftState left, CodexComposerDraftState right) =>
        left == CodexComposerDraftState.Present || right == CodexComposerDraftState.Present
            ? CodexComposerDraftState.Present
            : left == CodexComposerDraftState.Unknown || right == CodexComposerDraftState.Unknown
                ? CodexComposerDraftState.Unknown : CodexComposerDraftState.Empty;

    private static bool TryObject(JsonElement parent, string name, out JsonElement value)
    {
        value = default;
        return parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out value) &&
            value.ValueKind == JsonValueKind.Object;
    }
}
