using System.Text.Json.Nodes;
using CodexMicro.Codex;

namespace CodexMicro.Plugin;

internal static class KeypadCapabilities
{
    internal static JsonNode Read() => JsonSupport.Node(new
    {
        surface = "Original Codex Micro WPF keypad, core controls only",
        removed = new[] { "DeepSeek and external Harnesses", "Qwen3 ASR and local voice services", "additional keypad windows" },
        transport = "Codex desktop IPC + app-server",
        requiresDriver = false,
        implemented = new[]
        {
            "control/monitor panel switching",
            "six agent keys using the displayed roster",
            "new draft", "fork chat", "Fast service toggle",
            "single command/file approval or decline",
            "reasoning dial in reasoning mode", "configured quick models A/B",
            "MCP: explicit message submission and exact-turn interruption",
            "custom key/joystick bindings for the implemented actions"
        },
        unavailable = new[]
        {
            "native composer submit without explicit text",
            "native push-to-talk and realtime voice",
            "composer menus and selection", "conversation scrolling",
            "default joystick Plan/sidebar/back/forward navigation",
            "blank-draft model and reasoning changes",
            "arbitrary Codex UI commands and skill insertion",
            "hardware lighting and device settings"
        },
        limitation = "The current plugin interface has no equivalent entry point for these UI/device operations. Unsupported controls return NotSent; no input simulation or HID fallback is used.",
        verification = "Partial regression coverage. Implementation and transport acknowledgements do not establish complete live control acceptance."
    });
}
