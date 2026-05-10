# Source this file to deactivate the zellij-tmux-shim from fish.
# Usage: source deactivate.fish

if not set -q ZELLIJ_TMUX_SHIM_ACTIVE; or test -z "$ZELLIJ_TMUX_SHIM_ACTIVE"
    echo "zellij-tmux-shim: not active, nothing to deactivate" >&2
    return 0
end

# Kill any remaining wrapper processes and clean up their panes
if set -q ZELLIJ_TMUX_SHIM_STATE; and test -d "$ZELLIJ_TMUX_SHIM_STATE"
    command find "$ZELLIJ_TMUX_SHIM_STATE" -maxdepth 1 -name '*.pid' 2>/dev/null | while read -l _pidfile
        set -l _pid (cat "$_pidfile" 2>/dev/null)
        if test -n "$_pid"; and kill -0 "$_pid" 2>/dev/null
            kill "$_pid" 2>/dev/null
        end
    end
    rm -rf "$ZELLIJ_TMUX_SHIM_STATE"
end

# Restore original PATH (was saved as colon-separated string for portability)
if set -q ZELLIJ_TMUX_SHIM_ORIG_PATH; and test -n "$ZELLIJ_TMUX_SHIM_ORIG_PATH"
    set -gx PATH (string split : $ZELLIJ_TMUX_SHIM_ORIG_PATH)
end

# Unset all shim env vars
set -e TMUX
set -e TMUX_PANE
set -e ZELLIJ_TMUX_SHIM_ACTIVE
set -e ZELLIJ_TMUX_SHIM_DIR
set -e ZELLIJ_TMUX_SHIM_STATE
set -e ZELLIJ_TMUX_SHIM_REAL_TMUX
set -e ZELLIJ_TMUX_SHIM_ORIG_PATH
set -e ZELLIJ_TMUX_SHIM_DEBUG
