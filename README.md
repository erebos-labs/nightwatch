# nightwatch

Smart keep-awake for macOS. It wraps the built-in `caffeinate` with two
activity-aware modes, so your Mac stays awake **only while there's a reason to**
and then goes to sleep on its own.

- **`awake-goal`** — stay awake while a coding agent (Codex/Claude) is actively
  working; once the work goes quiet for a while, sleep. Good for *"finish this
  job overnight, then don't burn power till morning."*
- **`awake-away`** — stay fully awake now, then drop to **remote-ready** (the
  display may sleep, but the machine stays awake and reachable over the network)
  until a fixed window ends, then sleep. Good for *"I'm leaving the house but
  might want to drive this machine remotely in the next few hours."*

Plus the basics: `awake` (stay up until told otherwise, or for a fixed
duration) and `sleepy` (stop everything).

It's a single zsh file. No daemon to install, no dependencies beyond what ships
with macOS (`caffeinate`, `ps`, `awk`).

## Why not just `caffeinate`?

`caffeinate` keeps the Mac awake until you kill it — so you either babysit it or
leave the machine awake all night for a job that finished in 20 minutes.
nightwatch adds a lightweight watchdog that watches actual CPU activity of your
coding agents and decides when it's safe to let the machine sleep, plus a timed
"reachable but display-asleep" window for when you step out.

> **Why remote-ready instead of wake-on-demand?** Once a Mac is truly asleep,
> its network stack (and tools like Tailscale/SSH on it) is asleep too, so it's
> not a dependable remote wake button. nightwatch keeps the machine
> network-awake only for the window where you might need it, then sleeps.

## Commands

```
awake                 Keep the Mac fully awake until `sleepy`.
awake 2h              Keep the Mac fully awake for a fixed duration, then sleep.
awake-goal            Keep awake while Codex/Claude work is active; sleep after quiet.
awake-away 8h         Keep awake now, then remote-ready until the away window ends.
sleepy                Stop all keep-awake/watchdog modes; the Mac can sleep.
awake-status          Show current mode, phase, reason, and timers.
```

Options:

```
awake-goal --idle 10m --interval 30s [--max 4h]
awake-away 4h --idle 15m --interval 60s
```

- `--idle` — how long agent work must be quiet before sleeping (or, in away
  mode, before dropping to remote-ready). Default `15m`.
- `--interval` — how often the watchdog samples activity. Default `60s`.
- `--max` (goal mode only) — a hard cap; sleep after this long regardless.

Durations accept `s`, `m`, `h`, `d`, or a bare number of seconds.

## How "active" is decided

The watchdog snapshots the process table each interval and looks for processes
belonging to a coding agent — Codex Desktop, Claude Desktop, the Claude CLI, the
Claude Agent SDK — and the work children they spawn (`git`, `node`, `python`,
`cargo`, build tools, etc.). **Existence is not activity:** a process only counts
as active if it's new, currently running, or has burned a meaningful slice of
CPU since the last sample. An idle agent sitting at a prompt accrues no CPU and
will *not* keep your Mac awake.

You can tune the sensitivity with `NIGHTWATCH_CPU_DELTA_CS` (centiseconds of CPU
per interval that count as "active"; default `50`, i.e. 0.5s).

## Manual install

Requires macOS and zsh (the default shell on modern macOS).

```bash
# 1. Clone somewhere stable
git clone https://github.com/erebos-labs/nightwatch.git ~/.nightwatch-src

# 2. Source it from your ~/.zshrc
echo '[[ -r ~/.nightwatch-src/nightwatch.zsh ]] && source ~/.nightwatch-src/nightwatch.zsh' >> ~/.zshrc

# 3. Reload your shell
exec zsh
```

Then try `awake-status`, `awake-goal`, `sleepy`.

To update later: `git -C ~/.nightwatch-src pull`.

## Agentic install

Paste this block into a coding agent (Claude Code, Codex, etc.) and let it do
the install:

```text
Install the "nightwatch" macOS keep-awake zsh tool for me.

Reference: https://github.com/erebos-labs/nightwatch (README at
https://raw.githubusercontent.com/erebos-labs/nightwatch/main/README.md)

Steps:
1. Clone https://github.com/erebos-labs/nightwatch.git to ~/.nightwatch-src
   (if it already exists, `git -C ~/.nightwatch-src pull` instead).
2. Add this line to my ~/.zshrc if it isn't already present:
   [[ -r ~/.nightwatch-src/nightwatch.zsh ]] && source ~/.nightwatch-src/nightwatch.zsh
3. Run `zsh -n ~/.nightwatch-src/nightwatch.zsh` to confirm it parses.
4. Tell me the five commands (awake, awake 2h, awake-goal, awake-away, sleepy,
   awake-status) and confirm when done. Do NOT modify any other part of my zshrc.
```

## Configuration

All optional, set before sourcing (e.g. in `~/.zshrc`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `NIGHTWATCH_STATE_DIR` | `~/.nightwatch` | Where state/log files live. |
| `NIGHTWATCH_IDLE_SECONDS` | `900` | Default quiet threshold (`--idle`). |
| `NIGHTWATCH_INTERVAL_SECONDS` | `60` | Default sample interval (`--interval`). |
| `NIGHTWATCH_CPU_DELTA_CS` | `50` | CPU centiseconds/interval that count as active. |

## Optional: status hook (iTerm badge, tmux, notifications)

If you define a shell function named `nightwatch_notify` **before** sourcing
`nightwatch.zsh`, it is called with the current status string — one of `off`,
`on`, `goal`, `away`, `ready`, `timed` — whenever the status may have changed,
including a per-prompt refresh that catches background transitions.

Example: drive an iTerm2 badge.

```zsh
# In ~/.zshrc, BEFORE sourcing nightwatch.zsh:
nightwatch_notify() {
  [[ "$TERM_PROGRAM" == "iTerm.app" ]] || return 0
  local text
  case "$1" in
    goal)  text="AWAKE GOAL" ;;
    away)  text="AWAKE AWAY" ;;
    ready) text="AWAKE READY" ;;
    timed) text="AWAKE TIMED" ;;
    on)    text="AWAKE ON" ;;
    *)     text="AWAKE OFF" ;;
  esac
  printf '\e]1337;SetBadgeFormat=%s\a' "$(printf '%s' "$text" | base64 | tr -d '\n')"
}
source ~/.nightwatch-src/nightwatch.zsh
```

The same hook works for a tmux status segment, `terminal-notifier`, etc. —
nightwatch ships no terminal-specific code itself.

## Security & threat model

nightwatch is a local, single-user tool. It opens no network connections, runs
nothing as root, and accepts no input from outside your own shell — its only
"inputs" are the CLI arguments you type (validated to durations/numbers) and the
local process table read via `ps`. Design choices that keep it tight:

- **No pid-reuse kills.** Before signalling any pid it has stored, nightwatch
  confirms the pid is *still* a `caffeinate` (or its own watchdog), so a recycled
  pid can never cause it to kill an unrelated process.
- **Least blast radius.** The recovery `pkill` fallback (used only if the tracked
  pid was lost) is scoped to your own user's processes — it can never reach
  another account. Note it matches `caffeinate -dimsu`/`-imsu` by command line,
  so in that rare recovery path it would also stop a *separate* keep-awake
  caffeinate you started by hand; normal operation only ever signals the one pid
  nightwatch launched.
- **Owner-only state.** `NIGHTWATCH_STATE_DIR` is created `0700`. Its snapshot
  files contain the command lines of detected agent processes; if you pass
  secrets as command-line arguments to those agents, treat the state dir as
  sensitive (it stays in your home directory and is never transmitted).
- **Deterministic parsing.** The public functions run under `emulate -L zsh`, so
  unusual options in your `.zshrc` can't change how arguments are parsed or how
  processes are matched.
- **Dead-man backstop.** In timed modes (`awake-away`, and `awake-goal --max`),
  the `caffeinate` is launched with a `-t` timeout of the deadline plus a grace
  margin (`NIGHTWATCH_BACKSTOP_GRACE`, default 4h; accepts `4h`/`30m`/seconds). So
  even if the watchdog process is killed outright, the keep-awake self-expires
  instead of pinning the Mac awake indefinitely. The grace is slack on that
  self-expiry — `awake-away` uses it to keep going past its deadline while work is
  still active; for the `awake-goal --max` hard cap (which sleeps at the deadline)
  it only bounds how far a dead watchdog can overshoot. Set it to `0` to disable.

## State & logs

Runtime state (current mode, pids, timestamps) and a log of watchdog
transitions live under `NIGHTWATCH_STATE_DIR` (`~/.nightwatch` by default).
`sleepy` clears the live state. Nothing runs as root; nothing phones home.

## Uninstall

```bash
sleepy                         # stop any active mode
# remove the source line from ~/.zshrc
rm -rf ~/.nightwatch-src ~/.nightwatch
```

## License

MIT — see [LICENSE](LICENSE).
