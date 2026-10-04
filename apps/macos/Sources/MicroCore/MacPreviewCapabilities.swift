import Foundation

public enum MacPreviewCapabilities {
    public static let operations: Set<String> = [
        "get_keypad_capabilities", "list_keypad_threads", "get_keypad_models",
        "get_keypad_usage", "get_keypad_state", "open_keypad_thread", "get_keypad_layout",
        "set_keypad_model", "set_keypad_reasoning", "set_keypad_fast",
        "send_keypad_message", "stop_keypad_turn", "reply_keypad_approval", "toggle_keypad_plan"
    ]
    public static var description: [String: Any] { [
        "platform": "macOS 14+", "stage": "control-preview", "requiresDriver": false,
        "transport": "Local Codex desktop owner over Unix socket; read-only App Server catalog",
        "implemented": ["UIKit control/monitor keypad layout", "floating Catalyst window", "menu bar show/hide/quit",
            "recent task roster", "model and usage observation", "exact selected chat observation", "open existing chat",
            "existing-chat model/reasoning/Fast/Plan with readback", "exact command/file approval with readback", "exact active-turn stop with readback",
            "reasoning dial drag, wheel and accessibility input", "quick model A/B with per-preset effort", "local dial preferences and Codex binding observation", "configured joystick Plan direction",
            "explicit text submission through MCP"],
        "unavailable": ["layered settings", "new-draft controls", "fork",
            "foreground composer submit and navigation", "conversation scrolling", "joystick sidebar/back/forward", "full-roster unread observation", "voice"],
        "verification": "Build, static and headless protocol checks. Live UI and Codex mutation business acceptance are pending.",
        "limitation": "The selected ID is an explicit observation target, not a confirmed foreground chat. Unavailable status is never inferred as idle or unread."
    ] }
}
