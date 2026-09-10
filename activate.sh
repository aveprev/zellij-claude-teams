#!/usr/bin/env bash
# Source this file to activate the zellij-tmux-shim.
# Usage: source activate.sh

# Guard: only activate inside zellij
if [ -z "$ZELLIJ" ]; then
    echo "zellij-tmux-shim: not inside zellij, skipping activation" >&2
    return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# PATH guard
# ---------------------------------------------------------------------------
# Sourcing this file once is not enough. Tools that rewrite PATH wholesale
# (sdkman's `sdk use`, mise hook-env, direnv, nested login shells) can demote
# or drop the shim entry mid-session. Anything launched afterwards resolves the
# real tmux, which fails against our synthetic $TMUX socket — Claude Code then
# reports "Could not determine current tmux pane/window" and no teammate pane
# is ever created. Re-assert position 1 before every prompt so the next `claude`
# launch always inherits a correct PATH.
__zellij_tmux_shim_ensure_path() {
    [ -n "${ZELLIJ_TMUX_SHIM_ACTIVE:-}" ] || return 0
    [ -n "${ZELLIJ_TMUX_SHIM_DIR:-}" ] || return 0

    local _bin="${ZELLIJ_TMUX_SHIM_DIR}/bin"
    # Already in front: the common case, so do no work.
    case "$PATH" in
        "$_bin") return 0 ;;
        "$_bin":*) return 0 ;;
    esac

    # Drop every existing copy, then put ours back in front. The colon padding
    # lets the first and last entries match the same ":dir:" pattern as the
    # middle ones; the loop covers adjacent duplicates, which a single global
    # substitution would leave behind.
    local _rest=":${PATH}:"
    while :; do
        case "$_rest" in
            *":${_bin}:"*) _rest="${_rest//:${_bin}:/:}" ;;
            *) break ;;
        esac
    done
    _rest="${_rest#:}"
    _rest="${_rest%:}"

    PATH="${_bin}${_rest:+:${_rest}}"
    export PATH
}

# Register the guard with the shell's pre-prompt hook. Idempotent: re-sourcing
# this file (or a nested shell inheriting the registration) must not stack it.
__zellij_tmux_shim_install_path_hook() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        typeset -ga precmd_functions
        case " ${precmd_functions[*]} " in
            *" __zellij_tmux_shim_ensure_path "*) ;;
            *) precmd_functions+=(__zellij_tmux_shim_ensure_path) ;;
        esac
    elif [ -n "${BASH_VERSION:-}" ]; then
        # bash 5.1+ allows PROMPT_COMMAND to be an array; handle both forms.
        case "$(declare -p PROMPT_COMMAND 2>/dev/null)" in
            "declare -a"*)
                case " ${PROMPT_COMMAND[*]} " in
                    *" __zellij_tmux_shim_ensure_path "*) ;;
                    *) PROMPT_COMMAND+=(__zellij_tmux_shim_ensure_path) ;;
                esac
                ;;
            *)
                case "${PROMPT_COMMAND:-}" in
                    *__zellij_tmux_shim_ensure_path*) ;;
                    "") PROMPT_COMMAND="__zellij_tmux_shim_ensure_path" ;;
                    *) PROMPT_COMMAND="__zellij_tmux_shim_ensure_path; ${PROMPT_COMMAND}" ;;
                esac
                ;;
        esac
    fi
}

# Guard: don't double-activate — but always re-ensure PATH priority.
# Child shells inherit ZELLIJ_TMUX_SHIM_ACTIVE but rebuild PATH from
# shell config, pushing the shim behind other entries (brew, cargo, etc.).
# The guard above dedupes, so re-sourcing never stacks copies of the entry.
if [ -n "$ZELLIJ_TMUX_SHIM_ACTIVE" ]; then
    export ZELLIJ_TMUX_SHIM_DIR="${ZELLIJ_TMUX_SHIM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/zellij-tmux-shim}"
    __zellij_tmux_shim_ensure_path
    __zellij_tmux_shim_install_path_hook
    return 0 2>/dev/null || exit 0
fi

# XDG-compliant install directory
ZELLIJ_TMUX_SHIM_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zellij-tmux-shim"

# Runtime state goes in a ephemeral, per-user, per-session directory (PIDs, FIFOs, etc.)
# XDG_RUNTIME_DIR is /run/user/UID on systemd Linux; TMPDIR is per-user on macOS
# Scoped by ZELLIJ_SESSION_NAME so multiple zellij sessions don't collide.
_runtime_base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
_shim_root="${_runtime_base}/zellij-tmux-shim-$(id -u)"
ZELLIJ_TMUX_SHIM_STATE="${_shim_root}/${ZELLIJ_SESSION_NAME:-default}"
unset _runtime_base

# Save real tmux path before we shadow it
ZELLIJ_TMUX_SHIM_REAL_TMUX="$(command -v tmux 2>/dev/null || true)"
export ZELLIJ_TMUX_SHIM_REAL_TMUX

# Save original PATH for deactivation
ZELLIJ_TMUX_SHIM_ORIG_PATH="$PATH"
export ZELLIJ_TMUX_SHIM_ORIG_PATH

# Prepend shim bin to PATH so our tmux shadows the real one
export PATH="${ZELLIJ_TMUX_SHIM_DIR}/bin:${PATH}"

# Set fake tmux env vars so Claude Code thinks it's inside tmux
export TMUX="zellij-shim:/tmp/zellij-shim,$$,0"
export TMUX_PANE="%0"

# Export state dir for shim scripts
export ZELLIJ_TMUX_SHIM_DIR
export ZELLIJ_TMUX_SHIM_STATE

# Initialize state directory — this is the security keystone.
# FIFOs, eval'd env files, and command delivery all live here.
# chmod 700 MUST succeed; if it doesn't, the shim is unsafe.
# Secure the per-user root directory first, then create the per-session subdir.
if [ -L "$_shim_root" ]; then
    echo "zellij-tmux-shim: ERROR: state root is a symlink, refusing to activate" >&2
    unset _shim_root
    return 1 2>/dev/null || exit 1
fi
mkdir -p "$_shim_root"
chmod 700 "$_shim_root"
_owner=$(stat -c '%u' "$_shim_root" 2>/dev/null || stat -f '%u' "$_shim_root" 2>/dev/null)
if [ "$_owner" != "$(id -u)" ]; then
    echo "zellij-tmux-shim: ERROR: state root not owned by current user" >&2
    unset _shim_root _owner
    return 1 2>/dev/null || exit 1
fi
unset _owner
# Per-session subdir inherits root's 700 protection
mkdir -p "$ZELLIJ_TMUX_SHIM_STATE"
unset _shim_root

# Initialize next_id counter (start at 1, %0 is reserved for the host pane)
if [ ! -f "$ZELLIJ_TMUX_SHIM_STATE/next_id" ]; then
    echo "1" > "$ZELLIJ_TMUX_SHIM_STATE/next_id"
fi

# Initialize sessions file
if [ ! -f "$ZELLIJ_TMUX_SHIM_STATE/sessions" ]; then
    touch "$ZELLIJ_TMUX_SHIM_STATE/sessions"
fi

# Sweep stale state from prior crashed sessions: remove state files
# for PIDs that no longer exist.
# Uses find instead of a glob to avoid zsh NOMATCH error when no .pid files exist.
command find "$ZELLIJ_TMUX_SHIM_STATE" -maxdepth 1 -name '*.pid' 2>/dev/null | while IFS= read -r _pidfile; do
    _pid=$(cat "$_pidfile" 2>/dev/null)
    if [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; then
        _key="${_pidfile##*/}"
        _key="${_key%.pid}"
        rm -f "$ZELLIJ_TMUX_SHIM_STATE/${_key}.pid" \
              "$ZELLIJ_TMUX_SHIM_STATE/${_key}.zellij_id" \
              "$ZELLIJ_TMUX_SHIM_STATE/${_key}.fifo" \
              "$ZELLIJ_TMUX_SHIM_STATE/${_key}.ready" \
              "$ZELLIJ_TMUX_SHIM_STATE/${_key}.cmd" \
              "$ZELLIJ_TMUX_SHIM_STATE/${_key}.named" \
              "$ZELLIJ_TMUX_SHIM_STATE/${_key}.child" \
              "$ZELLIJ_TMUX_SHIM_STATE/${_key}.group"
    fi
done

# Clean up orphaned .zellij_id files (no matching .pid = dead pane)
command find "$ZELLIJ_TMUX_SHIM_STATE" -maxdepth 1 -name '*.zellij_id' 2>/dev/null | while IFS= read -r _idfile; do
    _key="${_idfile##*/}"
    _key="${_key%.zellij_id}"
    [ -f "$ZELLIJ_TMUX_SHIM_STATE/${_key}.pid" ] || rm -f "$_idfile"
done

# Remove stale env snapshot and lock from prior sessions
rm -f "$ZELLIJ_TMUX_SHIM_STATE/parent.env"
rm -rf "$ZELLIJ_TMUX_SHIM_STATE/next_id.lock"

export ZELLIJ_TMUX_SHIM_ACTIVE=1

# Keep the shim in front for the rest of this shell's life
__zellij_tmux_shim_install_path_hook
