import Foundation

public enum MacPreviewCapabilities {
    public static let operations: Set<String> = [
        "get_keypad_capabilities", "list_keypad_threads", "get_keypad_models", "get_keypad_activity", "get_keypad_client_thread",
        "get_keypad_usage", "get_keypad_state", "open_keypad_thread", "get_keypad_layout",
        "set_keypad_model", "set_keypad_reasoning", "set_keypad_fast",
        "send_keypad_message", "stop_keypad_turn", "reply_keypad_approval", "toggle_keypad_plan",
        "fork_keypad_thread", "new_keypad_thread", "open_keypad_review", "mark_keypad_unread",
        "get_keypad_folder", "open_keypad_folder", "open_keypad_developer_site", "open_keypad_settings", "open_keypad_skills", "get_keypad_archive_state", "open_keypad_tasks"
    ]
    public static var description: [String: Any] { [
        "platform": "macOS 14+", "stage": "control-preview", "requiresDriver": false,
        "transport": "Local Codex desktop owner over Unix socket; App Server catalog and guarded fork; bounded local state reads",
        "implemented": ["UIKit control/monitor keypad layout", "floating Catalyst window", "menu bar show/hide/quit",
            "recent task roster", "priority ranks the complete local interactive catalog by waiting/unread/active/idle and native recency; older candidates receive bounded fair activity discovery", "model and usage observation", "exact selected chat observation", "open existing chat",
            "local pinned task source reads the exact modern pinned section and server position order; unavailable identity or unsupported server never uses legacy global pins",
            "14 custom task slots persisted per account, host and storage scope; sparse slots retain positions and older exact chats resolve outside the recent page",
            "task mapping editor with full-ID choices, explicit recent-task snapshot, clear slot and stale-press rejection",
            "existing-chat model/reasoning/Fast/Plan with readback", "exact command/file approval with readback", "exact active-turn stop with readback",
            "reasoning dial drag, wheel and accessibility input", "quick model A/B with per-preset effort", "local dial preferences and Codex binding observation", "configured joystick Plan direction",
            "explicit text submission through MCP", "independent desktop activity stream and file-event status refresh",
            "canonical keycap action routing", "proportional command glyphs in a 28-point frame",
            "all 40 catalog keycaps selectable, including five no-op empty alternatives and fixed YOLO/YEET composer-text presets",
            "YOLO/YEET insertion at the exact UTF-16 caret or selection with text/caret readback; no Send, permission change or clipboard use",
            "Windows MIND slider artwork, 1.35 optical sizing and 180ms hover motion", "default effort resolution and bounded reasoning-key feedback",
            "independent visible-chat tracking and selected-chat settings subscriptions", "copyable chat ID and full model identity in settings",
            "Windows-style settings with local layout preferences", "keycap selection defaults to its matching action; explicit rebinding, save and cancel",
            "unified dial settings entry points and approval styling", "read-only recovery after uncertain settings changes",
            "target-scoped Fast/Plan/reasoning-key queue with per-operation readback", "account/host-scoped mark unread with persisted readback", "scroll dial press to bottom", "background submit press activates without sending",
            "confirmed ID-less native composer settings without guessing a chat ID",
            "developer website handoff to the default browser", "exact chat project folder handoff to Finder", "Codex settings and Skills page navigation with separate route verification",
            "exact-chat Pin/Unpin menu roundtrip", "native Copy as Markdown with fresh success notification and clipboard readback", "native Archive with retained confirmations and exact archived-list readback", "native application Terminal toggle with visible terminal-panel readback",
            "native browser-tab creation with a new visible panel in the same chat", "scheduled task management page navigation with exact route readback",
            "native feedback form opening with dialog readback and no submission", "new side chat from the exact parent chat with a new visible panel and ready composer",
            "native Files and folders picker handoff with a new Codex modal window; file selection and attachment completion stay with Codex",
            "dedicated native Select photos picker through the exact Add photos item or an explicit configured native shortcut; no general-files substitution",
            "native merge confirmation, commit/push, branch and regular/draft PR workflow forms with distinct branch prerequisite stage through the exact chat's command menu; no automatic Git mutation or form submission",
            "first configured environment action through the unfiltered Project command group and exact environmentAction1 terminal handoff; shell completion remains unverified",
            "split microphone layout", "recent-roster priority ordering and single/double-click task activation"],
        "conditional": ["photos require an observed Add photos item or a valid explicitly configured composer.addPhotos shortcut; no default shortcut is guessed","fork requires installed deferGoalContinuation schema; creation is read back before opening",
            "new draft and Review deep links; navigation verified only with exact native route/panel evidence",
            "foreground identity, composer submit, sidebar/history, composer selection, scrolling and Sketch require Accessibility and unambiguous native controls",
            "blank-draft settings use observed Power, Speed and Plan controls with readback; configured shortcuts are optional",
            "ID-less composer settings additionally require one selected sidebar element plus stable window, composer and picker identities; unavailable for known non-chat or conflicting routes",
            "Skill HTML clipboard insertion preserves concurrent copies and verifies the copied-back mention name and path; unavailable structure is an unknown outcome",
            "dictation requires the actual native control and Codex microphone permission",
            "visible roster rollout activity and async questions reconcile accepted desktop replies",
            "unread state requires the current account identity and an exact local stdio host bucket"],
        "unavailable": [ "Review close toggle", "realtime voice", "AgentController/XInput integration", "VHF/UMDF hardware emulation"],
        "verification": "Isolated model, process and Micro UI scenarios are separate from live Codex acceptance. Native controller replay replaces only OS effects; live Codex UI acceptance remains unverified.",
        "limitation": "Controls fail closed when the exact target, permission, supported protocol, native control or readback is unavailable. Unknown mutations are never replayed."
    ] }
}
