# zellij-claude-teams

Use [Claude Code](https://docs.anthropic.com/en/docs/claude-code) **Agent Teams** inside [Zellij](https://zellij.dev) — no tmux required.

## The Problem

Claude Code's Agent Teams feature spawns each teammate in its own terminal pane using **tmux**. If you use Zellij as your terminal multiplexer, Agent Teams silently falls back to in-process mode — no split panes, no visual separation.

## The Solution

This project provides a **tmux shim** — a fake `tmux` binary that intercepts Claude Code's tmux commands and translates them to `zellij action` equivalents. Agent teammates spawn as real Zellij panes within your current tab.

```
┌──────────────────────┬──────────────────────┐
│                      │  researcher          │
│   Claude Code        ├──────────────────────┤
│   (your session)     │  implementer         │
│                      ├──────────────────────┤
│                      │  tester              │
└──────────────────────┴──────────────────────┘
```

Agent panes are named after their role and stack vertically on the right.

## Requirements

- **Zellij** 0.40+ (tested on 0.43.1)
- **Bash** 3.2+ for the shim binaries (ships with macOS; Linux has 4+) — your interactive shell can be bash, zsh, or fish 3.6+
- **Claude Code** with Agent Teams support

## Installation

```bash
git clone https://github.com/stanislc/zellij-claude-teams.git
cd zellij-claude-teams
bash install.sh
```

The install script copies files to `${XDG_DATA_HOME:-~/.local/share}/zellij-tmux-shim/` and prints the activation snippet for your shell.

### Shell activation

Add **one** of these to your shell config:

**Bash** (`~/.bashrc`):
```bash
if [ -n "$ZELLIJ" ]; then
    _shim="${XDG_DATA_HOME:-$HOME/.local/share}/zellij-tmux-shim/activate.sh"
    [ -f "$_shim" ] && . "$_shim"
    unset _shim
fi
```

**Zsh** (`~/.zshrc`):
```zsh
if [[ -n "$ZELLIJ" ]]; then
    _shim="${XDG_DATA_HOME:-$HOME/.local/share}/zellij-tmux-shim/activate.sh"
    [[ -f "$_shim" ]] && source "$_shim"
    unset _shim
fi
```

**Fish** (`~/.config/fish/config.fish`):
```fish
if set -q ZELLIJ
    set -l _shim (set -q XDG_DATA_HOME; and echo $XDG_DATA_HOME; or echo $HOME/.local/share)/zellij-tmux-shim/activate.fish
    test -f $_shim; and source $_shim
end
```

Then restart your shell inside Zellij.

### Workspace trust (one-time)

Claude Code prompts for workspace trust per directory. To avoid each agent pane prompting individually, run `claude` once in your working directory and accept the trust dialog before using Agent Teams.

## Usage

Once activated, just use Claude Code normally inside Zellij:

```bash
claude           # start Claude Code
# Create a team → teammates appear as Zellij panes
```

The shim activates automatically when you're inside Zellij (it checks for the `$ZELLIJ` env var). Outside Zellij, it stays dormant.

### Deactivation

```bash
source ~/.local/share/zellij-tmux-shim/deactivate.sh
```

Fish users source `deactivate.fish` instead:

```fish
source ~/.local/share/zellij-tmux-shim/deactivate.fish
```

### Uninstall

```bash
cd zellij-claude-teams
bash install.sh --uninstall
# Then remove the activation snippet from your shell config
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `ZELLIJ_TMUX_SHIM_DEBUG` | unset | Set to `1` to log all tmux calls to `$STATE_DIR/shim.log` |

## Features

- **Pane naming** — each agent pane is titled with its role (researcher, implementer, etc.) via `zellij action rename-pane -p <pane-id>` (targeted by id, so it works regardless of which pane or tab is focused), which locks the title so Claude Code's TUI can't override it
- **Stacked layout** — the first agent splits right of the main pane; each additional agent is folded into a single Zellij *stack* on the right (collapsed to a one-row title bar, expanded when focused). Stacking sidesteps Zellij's minimum pane height, so large teams (8+) spawn reliably instead of failing once the column runs out of room
- **PATH guard** — the shim only works if its `bin/` is the *first* `tmux` on `PATH`. Sourcing `activate.*` once isn't enough: `sdk use`, `mise hook-env`, `direnv` and nested login shells rewrite `PATH` wholesale and can demote the entry. A pre-prompt hook (`fish_prompt` / `precmd_functions` / `PROMPT_COMMAND`) re-asserts position 1 before every command, deduping any stale copies
- **Session isolation** — state is scoped by `ZELLIJ_SESSION_NAME`, so multiple Zellij sessions don't collide
- **Tab isolation** — agent teams in different tabs within the same session are tracked independently via `.group` files
- **Tab pinning** — teammate panes are always created on the Claude Code tab, even if you've navigated to another tab. Before each split the shim focuses an anchor pane on the Claude tab (`focus-pane-id`), then restores your previous tab (`go-to-tab-by-id`) once the pane is placed — so spawning a teammate doesn't drag your view away

## How It Works

The shim uses a **FIFO-per-pane** architecture:

```
Claude Code                    Shim (bin/tmux)                 Zellij
───────────                    ───────────────                 ──────
tmux split-window -h ───────→  alloc pane ID (%1)
                               snapshot parent env
                               zellij new-pane ──────────────→ creates pane
                               wait for .ready sentinel        ↓
                                                               wrapper starts
                                                               creates FIFO
                                                               touches .ready
                               ← returns %1

tmux send-keys -t %1 "cmd" ─→ write "cmd" to FIFO
                                                               wrapper reads FIFO
                                                               rename-pane (locks title)
                                                               touch .named sentinel
                               wait for .named
                                                               eval "$cmd"
                                                               (cmd runs in pane)

tmux kill-pane -t %1 ───────→ kill PID from .pid file
                                                               process exits
                                                               --close-on-exit
                                                               pane auto-closes
```

### Environment forwarding

Zellij's `new-pane` does **not** inherit the parent shell's environment (unlike tmux). The shim works around this by:

1. `snapshot_env()` captures the parent environment via `export -p` to a file
2. The pane wrapper restores it with `eval "$(cat parent.env)"`
3. Per-pane variables (`TMUX_PANE`, state dir) are overridden after restore

### Concurrency

- **Pane ID allocation** uses `mkdir`-based locking (portable; macOS lacks `flock`)
- **Pane creation** is serialized by a second `mkdir` lock (`create.lock`). Claude Code launches teammates in parallel, and each spawn stacks the existing agents, splits, then re-stacks — steps that share the session's focus/stack state and must not interleave. Without the lock, concurrent spawns race and some panes fail to be created
- Stale lock detection via PID-in-lockdir: if the locker process is dead, the lock is reclaimed
- Each pane's state is in separate files, so most operations are naturally isolated

## Troubleshooting

### Panes appear and disappear instantly

- **Stdout redirect**: The shim must never redirect the command's stdout. Claude Code checks `isatty(stdout)` and exits if it detects a pipe.
- **Workspace trust**: If you haven't accepted trust for the working directory, Claude Code exits immediately. Run `claude` once in that directory first.

### Agent panes steal focus

Focus chains through agents during creation for correct layout placement. After all agents spawn, click the main pane to return keyboard focus. If you're on an older version, update to the latest.

### Teammates fail with "Could not determine current tmux pane/window"

Real `tmux` is answering instead of the shim. Claude Code takes the socket path from the synthetic `$TMUX` the shim exports, so the real binary fails with `error connecting to zellij-shim:/tmp/zellij-shim` and every teammate spawn dies. Check the resolution order in the pane:

```bash
command -v tmux   # must print .../zellij-tmux-shim/bin/tmux
```

If it prints `/opt/homebrew/bin/tmux` (or similar), something rewrote `PATH` after activation. The pre-prompt PATH guard repairs this before the next command, but a Claude Code session already running keeps the environment it was launched with — restart it:

```bash
source "${XDG_DATA_HOME:-$HOME/.local/share}/zellij-tmux-shim/activate.fish"  # or activate.sh
command -v tmux
claude ...
```

### Environment variables missing in panes

Ensure the shim is activated in your shell (check `echo $ZELLIJ_TMUX_SHIM_ACTIVE`). The shim snapshots your environment on first pane creation — variables set after activation but before the first `split-window` are captured.

### Debug logging

```bash
export ZELLIJ_TMUX_SHIM_DEBUG=1
# Use Claude Code normally, then inspect:
cat "${ZELLIJ_TMUX_SHIM_STATE}/shim.log"
```

## Known Limitations

- **No pane resizing** — Zellij manages layout automatically; tmux layout commands are no-ops
- **Large teams share one stack** — there's no hard cap on teammates, but agents collapse into a single Zellij stack, so only the focused agent is shown expanded at a time (navigate the stack with your Zellij keybindings)
- **Fragile to Claude Code updates** — new tmux commands added upstream may need shim updates. Debug logging captures unhandled commands for diagnosis.

## Compatibility

| Platform | Status |
|---|---|
| macOS (Apple Silicon) | Tested |
| macOS (Intel) | Should work |
| Linux (x86_64) | Should work (XDG-compliant paths, POSIX tools) |
| Linux (ARM) | Should work |
| WSL2 | Untested, likely works |

The shim avoids GNU-specific extensions:
- `export -p` instead of `env -0` for environment capture
- `mkdir`-based locking with PID stale detection instead of `flock` or `find -mmin`
- Fractional `sleep` with integer fallback
- Runtime state in `$XDG_RUNTIME_DIR` (Linux) or `$TMPDIR` (macOS)

## License

MIT
