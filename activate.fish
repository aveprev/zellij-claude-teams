# Source this file to activate the zellij-tmux-shim from fish.
# Usage: source activate.fish

# Guard: only activate inside zellij
if not set -q ZELLIJ; or test -z "$ZELLIJ"
    echo "zellij-tmux-shim: not inside zellij, skipping activation" >&2
    return 1
end

# Resolve XDG_DATA_HOME default
set -l _xdg_data_home
if set -q XDG_DATA_HOME; and test -n "$XDG_DATA_HOME"
    set _xdg_data_home $XDG_DATA_HOME
else
    set _xdg_data_home $HOME/.local/share
end

# Guard: don't double-activate — but always re-ensure PATH priority.
# Child shells inherit ZELLIJ_TMUX_SHIM_ACTIVE but rebuild PATH from
# shell config, pushing the shim behind other entries (brew, cargo, etc.).
if set -q ZELLIJ_TMUX_SHIM_ACTIVE; and test -n "$ZELLIJ_TMUX_SHIM_ACTIVE"
    set -l _existing_dir
    if set -q ZELLIJ_TMUX_SHIM_DIR; and test -n "$ZELLIJ_TMUX_SHIM_DIR"
        set _existing_dir $ZELLIJ_TMUX_SHIM_DIR
    else
        set _existing_dir $_xdg_data_home/zellij-tmux-shim
    end
    set -gx PATH $_existing_dir/bin $PATH
    return 0
end

# XDG-compliant install directory
set -gx ZELLIJ_TMUX_SHIM_DIR $_xdg_data_home/zellij-tmux-shim

# Runtime state goes in a ephemeral, per-user, per-session directory (PIDs, FIFOs, etc.)
# XDG_RUNTIME_DIR is /run/user/UID on systemd Linux; TMPDIR is per-user on macOS
# Scoped by ZELLIJ_SESSION_NAME so multiple zellij sessions don't collide.
set -l _runtime_base
if set -q XDG_RUNTIME_DIR; and test -n "$XDG_RUNTIME_DIR"
    set _runtime_base $XDG_RUNTIME_DIR
else if set -q TMPDIR; and test -n "$TMPDIR"
    set _runtime_base $TMPDIR
else
    set _runtime_base /tmp
end
set -l _shim_root $_runtime_base/zellij-tmux-shim-(id -u)
set -l _session_name default
if set -q ZELLIJ_SESSION_NAME; and test -n "$ZELLIJ_SESSION_NAME"
    set _session_name $ZELLIJ_SESSION_NAME
end
set -gx ZELLIJ_TMUX_SHIM_STATE $_shim_root/$_session_name

# Save real tmux path before we shadow it
set -gx ZELLIJ_TMUX_SHIM_REAL_TMUX (command -v tmux 2>/dev/null; or true)

# Save original PATH for deactivation (flatten fish list to colon-separated string
# so it survives child processes as a normal env var)
set -gx ZELLIJ_TMUX_SHIM_ORIG_PATH (string join : $PATH)

# Prepend shim bin to PATH so our tmux shadows the real one
set -gx PATH $ZELLIJ_TMUX_SHIM_DIR/bin $PATH

# Set fake tmux env vars so Claude Code thinks it's inside tmux
set -gx TMUX "zellij-shim:/tmp/zellij-shim,$fish_pid,0"
set -gx TMUX_PANE "%0"

# Initialize state directory — this is the security keystone.
# FIFOs, eval'd env files, and command delivery all live here.
# chmod 700 MUST succeed; if it doesn't, the shim is unsafe.
# Secure the per-user root directory first, then create the per-session subdir.
if test -L "$_shim_root"
    echo "zellij-tmux-shim: ERROR: state root is a symlink, refusing to activate" >&2
    return 1
end
mkdir -p "$_shim_root"
chmod 700 "$_shim_root"
set -l _owner (stat -c '%u' "$_shim_root" 2>/dev/null; or stat -f '%u' "$_shim_root" 2>/dev/null)
if test "$_owner" != (id -u)
    echo "zellij-tmux-shim: ERROR: state root not owned by current user" >&2
    return 1
end
# Per-session subdir inherits root's 700 protection
mkdir -p "$ZELLIJ_TMUX_SHIM_STATE"

# Initialize next_id counter (start at 1, %0 is reserved for the host pane)
if not test -f "$ZELLIJ_TMUX_SHIM_STATE/next_id"
    echo "1" > "$ZELLIJ_TMUX_SHIM_STATE/next_id"
end

# Initialize sessions file
if not test -f "$ZELLIJ_TMUX_SHIM_STATE/sessions"
    touch "$ZELLIJ_TMUX_SHIM_STATE/sessions"
end

# Sweep stale state from prior crashed sessions: remove state files
# for PIDs that no longer exist.
# Uses find instead of a glob to avoid errors when no .pid files exist.
command find "$ZELLIJ_TMUX_SHIM_STATE" -maxdepth 1 -name '*.pid' 2>/dev/null | while read -l _pidfile
    set -l _pid (cat "$_pidfile" 2>/dev/null)
    if test -n "$_pid"; and not kill -0 "$_pid" 2>/dev/null
        set -l _key (path basename "$_pidfile")
        set _key (string replace -r '\.pid$' '' $_key)
        rm -f "$ZELLIJ_TMUX_SHIM_STATE/$_key.pid" \
              "$ZELLIJ_TMUX_SHIM_STATE/$_key.zellij_id" \
              "$ZELLIJ_TMUX_SHIM_STATE/$_key.fifo" \
              "$ZELLIJ_TMUX_SHIM_STATE/$_key.ready" \
              "$ZELLIJ_TMUX_SHIM_STATE/$_key.cmd" \
              "$ZELLIJ_TMUX_SHIM_STATE/$_key.named" \
              "$ZELLIJ_TMUX_SHIM_STATE/$_key.child" \
              "$ZELLIJ_TMUX_SHIM_STATE/$_key.group"
    end
end

# Clean up orphaned .zellij_id files (no matching .pid = dead pane)
command find "$ZELLIJ_TMUX_SHIM_STATE" -maxdepth 1 -name '*.zellij_id' 2>/dev/null | while read -l _idfile
    set -l _key (path basename "$_idfile")
    set _key (string replace -r '\.zellij_id$' '' $_key)
    if not test -f "$ZELLIJ_TMUX_SHIM_STATE/$_key.pid"
        rm -f "$_idfile"
    end
end

# Remove stale env snapshot and lock from prior sessions
rm -f "$ZELLIJ_TMUX_SHIM_STATE/parent.env"
rm -rf "$ZELLIJ_TMUX_SHIM_STATE/next_id.lock"

set -gx ZELLIJ_TMUX_SHIM_ACTIVE 1
