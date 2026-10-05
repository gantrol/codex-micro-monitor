using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Tomlyn;
using Tomlyn.Syntax;

namespace CodexMicro.Desktop.Services;

/// <summary>
/// Updates only the Codex Micro TOML tables and preserves every unrelated
/// Codex setting. Writes use the same atomic replacement pattern observed by
/// <see cref="CodexMicroLayoutObserver"/>.
/// </summary>
internal sealed class CodexMicroConfigWriter
{
    private const string LayoutTable = "desktop.codex-micro-layout";

    private static readonly HashSet<string> SlotIds = new(
        [
            "ACT06",
            "ACT07",
            "ACT08",
            "ACT09",
            "ACT10",
            "ACT11",
            "ACT10_ACT11",
            "ACT12",
        ],
        StringComparer.Ordinal);

    private readonly string _configPath;
    private readonly SemaphoreSlim _updates = new(1, 1);

    internal CodexMicroConfigWriter(string configPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(configPath);
        _configPath = configPath;
    }

    internal string ConfigPath => _configPath;

    internal bool SetSlot(
        string slotId,
        string keycapId,
        CodexMicroActionBinding? action,
        Func<bool>? saveIcon = null)
        => SetSlotBinding(
            slotId,
            new CodexMicroSlotBinding(keycapId, null, action),
            saveIcon);

    internal bool SetSlotBinding(
        string slotId,
        CodexMicroSlotBinding binding,
        Func<bool>? saveIcon = null)
    {
        if (!SlotIds.Contains(slotId))
        {
            throw new ArgumentOutOfRangeException(nameof(slotId));
        }

        ArgumentNullException.ThrowIfNull(binding);
        if (!CodexKeycapCatalog.IsKnown(binding.KeycapId))
        {
            throw new ArgumentOutOfRangeException(nameof(binding));
        }

        var actionValue = binding.Action switch
        {
            null => null,
            { Type: "command" } commandAction =>
                $"{{ type = \"command\", commandId = {TomlString(commandAction.Id)} }}",
            { Type: "skill", SkillPath: { Length: > 0 } path }
                skillAction =>
                $"{{ type = \"skill\", skillName = {TomlString(skillAction.Id)}, " +
                $"skillPath = {TomlString(path)} }}",
            _ => throw new ArgumentOutOfRangeException(nameof(binding)),
        };

        return Update(text => UpsertTable(
            text,
            $"{LayoutTable}.slots.{slotId}",
            new Dictionary<string, string?>(StringComparer.Ordinal)
            {
                ["keycapId"] = TomlString(binding.KeycapId),
                ["commandId"] = string.IsNullOrWhiteSpace(binding.CommandId)
                    ? null
                    : TomlString(binding.CommandId),
                ["action"] = actionValue,
            }), saveIcon);
    }

    internal bool SetEncoderMode(string mode)
    {
        if (mode is not (
            "composer-navigation" or
            "reasoning" or
            "conversation-scroll" or
            "custom"))
        {
            throw new ArgumentOutOfRangeException(nameof(mode));
        }

        return SetLayoutValue("encoderMode", TomlString(mode));
    }

    internal bool SetVoiceButtonMode(string mode)
    {
        if (mode is not ("push-to-talk" or "realtime"))
        {
            throw new ArgumentOutOfRangeException(nameof(mode));
        }

        return SetLayoutValue("voiceButtonMode", TomlString(mode));
    }

    internal bool SetSeparateMicrophoneKeys(bool value) =>
        SetLayoutValue("separateMicrophoneKeys", value ? "true" : "false");

    internal Task<bool> SetSeparateMicrophoneKeysAsync(bool value, CancellationToken cancellationToken = default) =>
        UpdateAsync(text => UpsertTable(text, LayoutTable,
            new Dictionary<string, string?>(StringComparer.Ordinal)
            {
                ["separateMicrophoneKeys"] = value ? "true" : "false",
            }), cancellationToken);

    internal bool ResetLayout() => Update(RemoveAndAppendDefaultLayout);

    internal Task<bool> ResetLayoutAsync(CancellationToken cancellationToken) =>
        UpdateAsync(RemoveAndAppendDefaultLayout, cancellationToken);

    internal Task<bool> SetEncoderModeAsync(string mode, CancellationToken cancellationToken)
    {
        if (mode is not ("composer-navigation" or "reasoning" or "conversation-scroll" or "custom"))
            throw new ArgumentOutOfRangeException(nameof(mode));
        return UpdateAsync(text => UpsertTable(text, LayoutTable,
            new Dictionary<string, string?> { ["encoderMode"] = TomlString(mode) }), cancellationToken);
    }

    internal Task<bool> SetAnalogActionAsync(string direction, string action, CancellationToken cancellationToken)
    {
        if (direction is not ("up" or "right" or "down" or "left"))
            throw new ArgumentOutOfRangeException(nameof(direction));
        if (action != "unassigned" && !CodexActionCatalog.All.Any(item => item.Id == action && item.SoftwareSupported))
            throw new ArgumentOutOfRangeException(nameof(action));
        return UpdateAsync(text => UpsertTable(text, $"{LayoutTable}.analogStick.{direction}",
            new Dictionary<string, string?>
            {
                ["commandId"] = TomlString(action), ["skillName"] = null, ["skillPath"] = null,
            }), cancellationToken);
    }

    private bool SetLayoutValue(string key, string value) =>
        Update(text => UpsertTable(
            text,
            LayoutTable,
            new Dictionary<string, string?>(StringComparer.Ordinal)
            {
                [key] = value,
            }));

    private bool Update(Func<string, string> update, Func<bool>? completeSave = null)
    {
        if (!_updates.Wait(0)) return false;
        var temporaryPath = _configPath + ".micro." + Guid.NewGuid().ToString("N") + ".tmp";
        var backupPath = temporaryPath + ".bak";
        var hadOriginal = false;
        var committed = false;
        var completed = false;
        var rollbackFailed = false;
        string? committedText = null;
        try
        {
            hadOriginal = File.Exists(_configPath);
            var source = hadOriginal
                ? File.ReadAllText(_configPath)
                : string.Empty;
            if (Toml.Parse(source).HasErrors) return false;
            var next = update(source);
            if (Toml.Parse(next).HasErrors) return false;
            var directory = Path.GetDirectoryName(_configPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.WriteAllText(
                temporaryPath,
                next,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            if (completeSave is not null && hadOriginal)
                File.Replace(temporaryPath, _configPath, backupPath);
            else
                File.Move(temporaryPath, _configPath, overwrite: true);
            committed = true;
            committedText = next;
            completed = completeSave?.Invoke() ?? true;
            return completed;
        }
        catch (Exception exception) when (
            exception is IOException or
                UnauthorizedAccessException or
                JsonException)
        {
            return false;
        }
        finally
        {
            if (committed && !completed)
            {
                try
                {
                    // Restore the original bytes, including encoding and comments.
                    if (File.ReadAllText(_configPath) != committedText)
                        rollbackFailed = true;
                    else if (hadOriginal) File.Move(backupPath, _configPath, overwrite: true);
                    else File.Delete(_configPath);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    // Leave the backup available if another process prevents recovery.
                    rollbackFailed = true;
                }
            }
            DeleteTemporaryFile(temporaryPath);
            if (!rollbackFailed) DeleteTemporaryFile(backupPath);
            _updates.Release();
        }
    }

    private async Task<bool> UpdateAsync(Func<string, string> update, CancellationToken cancellationToken)
    {
        await _updates.WaitAsync(cancellationToken).ConfigureAwait(false);
        var temporaryPath = _configPath + ".micro." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var source = File.Exists(_configPath)
                ? await File.ReadAllTextAsync(_configPath, cancellationToken).ConfigureAwait(false)
                : string.Empty;
            if (Toml.Parse(source).HasErrors) return false;
            var next = update(source);
            if (Toml.Parse(next).HasErrors) return false;
            var directory = Path.GetDirectoryName(_configPath);
            if (!string.IsNullOrWhiteSpace(directory)) Directory.CreateDirectory(directory);
            await File.WriteAllTextAsync(temporaryPath, next, new UTF8Encoding(false), cancellationToken).ConfigureAwait(false);
            // Preserve a configuration edited externally while the asynchronous write was pending.
            var current = File.Exists(_configPath)
                ? await File.ReadAllTextAsync(_configPath, cancellationToken).ConfigureAwait(false)
                : string.Empty;
            if (current != source) return false;
            cancellationToken.ThrowIfCancellationRequested();
            File.Move(temporaryPath, _configPath, overwrite: true);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return false;
        }
        finally
        {
            DeleteTemporaryFile(temporaryPath);
            _updates.Release();
        }
    }

    private static void DeleteTemporaryFile(string path)
    {
        try { File.Delete(path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    private static string UpsertTable(
        string source,
        string tableName,
        IReadOnlyDictionary<string, string?> updates)
    {
        source = ExpandInlineAncestor(source, tableName);
        var newline = source.Contains("\r\n", StringComparison.Ordinal)
            ? "\r\n"
            : "\n";
        var lines = NormalizeLines(source);
        var header = $"[{tableName}]";
        var start = lines.FindIndex(line =>
            string.Equals(line.Trim(), header, StringComparison.Ordinal));
        if (start < 0)
        {
            while (lines.Count > 0 && lines[^1].Length == 0)
            {
                lines.RemoveAt(lines.Count - 1);
            }

            if (lines.Count > 0)
            {
                lines.Add(string.Empty);
            }

            lines.Add(header);
            foreach (var (key, value) in updates)
            {
                if (value is not null)
                {
                    lines.Add($"{key} = {value}");
                }
            }

            lines.Add(string.Empty);
            return JoinLines(lines, newline);
        }

        var end = FindNextHeader(lines, start + 1);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var replacement = new List<string> { lines[start] };
        for (var index = start + 1; index < end; index++)
        {
            var line = lines[index];
            var key = TryReadAssignmentKey(line);
            if (key is null || !updates.TryGetValue(key, out var value))
            {
                replacement.Add(line);
                continue;
            }

            if (seen.Add(key) && value is not null)
            {
                replacement.Add($"{key} = {value}");
            }
        }

        foreach (var (key, value) in updates)
        {
            if (value is not null && seen.Add(key))
            {
                replacement.Add($"{key} = {value}");
            }
        }

        lines.RemoveRange(start, end - start);
        lines.InsertRange(start, replacement);
        return JoinLines(lines, newline);
    }

    // Inline tables are closed to later table declarations. Expand only the
    // ancestor containing this edit; retain all unrelated text and inline values.
    private static string ExpandInlineAncestor(string source, string tableName)
    {
        var document = Toml.Parse(source);
        // Update and UpdateAsync only call this with a validated syntax tree.
        var target = tableName.Split('.');
        var candidates = document.KeyValues.Select(item => (Path: ReadKey(item.Key!), Item: item))
            .Concat(document.Tables.OfType<TableSyntax>().SelectMany(table =>
                table.Items.Select(item => (Path: ReadKey(table.Name!).Concat(ReadKey(item.Key!)).ToArray(), Item: item))));
        foreach (var (path, item) in candidates)
        {
            if (item.Value is not InlineTableSyntax inline || !IsAncestor(path, target)) continue;
            var newline = source.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
            var tables = new StringBuilder();
            AppendExpandedTable(tables, source, path, target, inline, newline);
            // Leave the original trailing comment in place rather than deleting it.
            var start = item.Key!.Span.Start.Offset;
            var end = inline.CloseBrace!.Span.End.Offset + 1;
            return source.Remove(start, end - start).TrimEnd('\r', '\n') + newline + newline + tables;
        }
        return source;
    }

    private static void AppendExpandedTable(
        StringBuilder output, string source, string[] path, string[] target,
        InlineTableSyntax inline, string newline)
    {
        output.Append('[').AppendJoin('.', path).Append(']').Append(newline);
        var children = new List<(string[] Path, InlineTableSyntax Table)>();
        foreach (var item in inline.Items)
        {
            var entry = item.KeyValue!;
            var childPath = path.Concat(ReadKey(entry.Key!)).ToArray();
            if (entry.Value is InlineTableSyntax child && IsAncestor(childPath, target))
            {
                children.Add((childPath, child));
                continue;
            }
            output.Append(source.AsSpan(entry.Key!.Span.Start.Offset, entry.Key.Span.Length))
                .Append(" = ")
                .Append(source.AsSpan(entry.Value!.Span.Start.Offset, entry.Value.Span.Length))
                .Append(newline);
        }
        foreach (var child in children)
        {
            output.Append(newline);
            AppendExpandedTable(output, source, child.Path, target, child.Table, newline);
        }
    }

    private static bool IsAncestor(string[] path, string[] target) =>
        path.Length <= target.Length && path.SequenceEqual(target.Take(path.Length));

    private static string[] ReadKey(KeySyntax key) =>
        new[] { key.Key }.Concat(key.DotKeys.Select(part => part.Key))
            .Select(part => part switch
            {
                BareKeySyntax bare => bare.Key!.Text!,
                StringValueSyntax quoted => quoted.Value!,
                _ => throw new InvalidOperationException("Invalid TOML key."),
            }).ToArray();

    private static string RemoveAndAppendDefaultLayout(string source)
    {
        source = ExpandInlineAncestor(source, LayoutTable);
        var newline = source.Contains("\r\n", StringComparison.Ordinal)
            ? "\r\n"
            : "\n";
        var kept = new List<string>();
        var skipping = false;
        foreach (var line in NormalizeLines(source))
        {
            if (TryReadTableName(line) is { } table)
            {
                skipping = table == LayoutTable ||
                    table.StartsWith(LayoutTable + ".", StringComparison.Ordinal);
            }

            if (!skipping)
            {
                kept.Add(line);
            }
        }

        while (kept.Count > 0 && kept[^1].Length == 0)
        {
            kept.RemoveAt(kept.Count - 1);
        }

        if (kept.Count > 0)
        {
            kept.Add(string.Empty);
        }

        kept.AddRange(DefaultLayoutLines);
        kept.Add(string.Empty);
        return JoinLines(kept, newline);
    }

    private static readonly string[] DefaultLayoutLines =
    [
        "[desktop.codex-micro-layout]",
        "version = 1",
        "encoderMode = \"composer-navigation\"",
        "voiceButtonMode = \"push-to-talk\"",
        "separateMicrophoneKeys = false",
        "",
        "[desktop.codex-micro-layout.slots.ACT06]",
        "keycapId = \"FAST\"",
        "",
        "[desktop.codex-micro-layout.slots.ACT07]",
        "keycapId = \"APPR\"",
        "",
        "[desktop.codex-micro-layout.slots.ACT08]",
        "keycapId = \"REJ\"",
        "",
        "[desktop.codex-micro-layout.slots.ACT09]",
        "keycapId = \"SPLIT\"",
        "",
        "[desktop.codex-micro-layout.slots.ACT10]",
        "keycapId = \"MIC1\"",
        "",
        "[desktop.codex-micro-layout.slots.ACT11]",
        "keycapId = \"EMPT1\"",
        "",
        "[desktop.codex-micro-layout.slots.ACT10_ACT11]",
        "keycapId = \"MIC\"",
        "",
        "[desktop.codex-micro-layout.slots.ACT12]",
        "keycapId = \"CODEX\"",
        "",
        "[desktop.codex-micro-layout.analogStick.up]",
        "commandId = \"composer.togglePlanMode\"",
        "",
        "[desktop.codex-micro-layout.analogStick.right]",
        "commandId = \"navigateForward\"",
        "",
        "[desktop.codex-micro-layout.analogStick.down]",
        "commandId = \"toggleSidebar\"",
        "",
        "[desktop.codex-micro-layout.analogStick.left]",
        "commandId = \"navigateBack\"",
    ];

    private static List<string> NormalizeLines(string source) =>
        source.Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n')
            .Split('\n')
            .ToList();

    private static string JoinLines(List<string> lines, string newline) =>
        string.Join(newline, lines);

    private static int FindNextHeader(IReadOnlyList<string> lines, int start)
    {
        for (var index = start; index < lines.Count; index++)
        {
            if (TryReadTableName(lines[index]) is not null)
            {
                return index;
            }
        }

        return lines.Count;
    }

    private static string? TryReadTableName(string line)
    {
        var trimmed = line.Trim();
        return trimmed.Length >= 3 && trimmed[0] == '[' && trimmed[^1] == ']'
            ? trimmed.Trim('[', ']').Trim()
            : null;
    }

    private static string? TryReadAssignmentKey(string line)
    {
        var match = Regex.Match(
            line,
            "^\\s*(?<key>[A-Za-z0-9_-]+)\\s*=",
            RegexOptions.CultureInvariant);
        return match.Success ? match.Groups["key"].Value : null;
    }

    private static string TomlString(string value) =>
        JsonSerializer.Serialize(value);
}
