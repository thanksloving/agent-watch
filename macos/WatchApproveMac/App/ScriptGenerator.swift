import Foundation

struct ScriptGenerator {
    static func generateApproveScript(relayURL: String, hookToken: String, scriptPath: String) -> String {
        """
        #!/bin/bash
        # WatchApprove Pro — Claude Code PreToolUse hook
        WATCH_RELAY_URL="\(relayURL)"
        WATCH_HOOK_TOKEN="\(hookToken)"
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

        if [ -f "$SCRIPT_DIR/watch.env" ]; then
            set -a; source "$SCRIPT_DIR/watch.env"; set +a
        fi

        exec python3 "$SCRIPT_DIR/watch_approve.py"
        """
    }
}
