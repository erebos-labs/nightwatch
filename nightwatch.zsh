# nightwatch - smart keep-awake controls for macOS.
#
# Defines the `awake`, `sleepy`, `awake-goal`, `awake-away`, and `awake-status`
# zsh functions. It wraps macOS `caffeinate` with two activity-aware modes:
#
#   awake-goal   Stay awake while Codex/Claude work is active; sleep after it
#                goes quiet (good for "finish this overnight, then sleep").
#   awake-away   Stay fully awake now, then drop to remote-ready (display may
#                sleep, network stays reachable) until a fixed window ends
#                (good for "I'm leaving but might drive the machine remotely").
#
# These are plain shell functions. If `awake`/`sleepy` collide with something
# else in your setup, rename the functions at the bottom of this file.
#
# Optional integration hook: if you define a shell function named
# `nightwatch_notify`, it is called with the current status string ("off",
# "on", "goal", "away", "ready", "timed") whenever the status may have changed.
# Use it to drive an iTerm badge, a tmux segment, a desktop notification, etc.
# See the README for an iTerm badge example. Define it *before* sourcing this
# file if you want the per-prompt refresh hook installed.

# Resolve to an absolute, symlink-collapsed path so the watchdog can re-source
# this file regardless of the cwd it is later launched from.
typeset -g NIGHTWATCH_SCRIPT="${NIGHTWATCH_SCRIPT:-${${(%):-%x}:A}}"
typeset -g NIGHTWATCH_STATE_DIR="${NIGHTWATCH_STATE_DIR:-$HOME/.nightwatch}"
typeset -g NIGHTWATCH_IDLE_SECONDS="${NIGHTWATCH_IDLE_SECONDS:-900}"
typeset -g NIGHTWATCH_INTERVAL_SECONDS="${NIGHTWATCH_INTERVAL_SECONDS:-60}"
typeset -g NIGHTWATCH_CPU_DELTA_CS="${NIGHTWATCH_CPU_DELTA_CS:-50}"
# Dead-man backstop for away mode: its caffeinate is given a -t timeout of
# (deadline - now + this grace) so it self-expires even if the watchdog process
# dies, instead of pinning the Mac awake forever. The grace preserves "stay awake
# past the deadline while work is still active" up to this margin. Accepts a
# duration (4h/30m/seconds); set to 0 to disable the backstop.
typeset -g NIGHTWATCH_BACKSTOP_GRACE="${NIGHTWATCH_BACKSTOP_GRACE:-14400}"

# Prefer zsh's own strftime for epoch formatting so we don't depend on BSD
# `date -r` (which breaks if GNU coreutils is ahead of it on PATH).
zmodload zsh/datetime 2>/dev/null || true

_nightwatch_state_dir() {
  # State/log files record process command lines, so keep the dir owner-only.
  [[ -d "$NIGHTWATCH_STATE_DIR" ]] || mkdir -p "$NIGHTWATCH_STATE_DIR"
  chmod 700 "$NIGHTWATCH_STATE_DIR" 2>/dev/null || true
}

# True only if $1 is a live pid whose command line contains $2. Guards every
# kill/running check against pid reuse: we never signal a pid unless it is
# still the kind of process we launched.
_nightwatch_pid_is() {
  local pid="$1" needle="$2" cmd
  [[ "$pid" == <-> ]] || return 1
  cmd="$(ps -p "$pid" -o command= 2>/dev/null)" || return 1
  [[ -n "$cmd" && "$cmd" == *"$needle"* ]]
}

_nightwatch_state_path() {
  print -r -- "$NIGHTWATCH_STATE_DIR/$1"
}

_nightwatch_state_set() {
  _nightwatch_state_dir
  printf '%s\n' "$2" > "$(_nightwatch_state_path "$1")"
}

_nightwatch_state_get() {
  local path value
  path="$(_nightwatch_state_path "$1")"
  [[ -f "$path" ]] || return 1
  IFS= read -r value < "$path" || true
  print -r -- "$value"
}

_nightwatch_state_rm() {
  rm -f "$(_nightwatch_state_path "$1")"
}

_nightwatch_log() {
  _nightwatch_state_dir
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$(_nightwatch_state_path log)"
}

_nightwatch_now() {
  date +%s
}

# Seconds for an auto-mode caffeinate's -t backstop, or non-zero exit (no output)
# when the mode has no deadline (deadline 0) or the backstop is disabled. Bounds
# the lease to the deadline plus NIGHTWATCH_BACKSTOP_GRACE so a dead watchdog can
# never leave caffeinate running indefinitely.
_nightwatch_backstop_t() {
  emulate -L zsh
  local deadline="$1" now grace remaining
  [[ "$deadline" == <-> && "$deadline" -gt 0 ]] || return 1
  # Validate grace like every other duration input (accepts 4h/30m/seconds);
  # fall back to the 4h default rather than silently dropping the safety timeout
  # if it is misconfigured. A grace of 0 is valid and disables the backstop.
  grace="$(_nightwatch_duration_seconds "$NIGHTWATCH_BACKSTOP_GRACE" 2>/dev/null)" || grace=14400
  (( grace > 0 )) || return 1
  now="$(_nightwatch_now)"
  remaining=$(( deadline - now + grace ))
  (( remaining < 1 )) && remaining=1
  print -r -- "$remaining"
}

_nightwatch_duration_seconds() {
  local raw number unit
  raw="$1"

  if [[ "$raw" == <-> ]]; then
    print -r -- "$raw"
    return 0
  fi

  if [[ "$raw" =~ '^([0-9]+)([smhd])$' ]]; then
    number="$match[1]"
    unit="$match[2]"

    case "$unit" in
      s) print -r -- "$number" ;;
      m) print -r -- "$(( number * 60 ))" ;;
      h) print -r -- "$(( number * 3600 ))" ;;
      d) print -r -- "$(( number * 86400 ))" ;;
    esac
    return 0
  fi

  print -u2 "Expected a duration like 15m, 4h, 8h, or seconds."
  return 1
}

_nightwatch_format_duration() {
  local seconds days hours minutes
  seconds="$1"
  # Defense in depth: never feed a non-integer into arithmetic.
  [[ "$seconds" == <-> ]] || seconds=0

  days=$(( seconds / 86400 ))
  hours=$(( (seconds % 86400) / 3600 ))
  minutes=$(( (seconds % 3600) / 60 ))

  if (( days > 0 )); then
    printf '%dd%02dh' "$days" "$hours"
  elif (( hours > 0 )); then
    printf '%dh%02dm' "$hours" "$minutes"
  elif (( minutes > 0 )); then
    printf '%dm' "$minutes"
  else
    printf '%ds' "$seconds"
  fi
}

_nightwatch_time_label() {
  local epoch
  epoch="$1"
  if [[ "$epoch" == <-> && "$epoch" -gt 0 ]]; then
    if (( $+builtins[strftime] )); then
      strftime '%Y-%m-%d %H:%M:%S %Z' "$epoch"
    else
      date -r "$epoch" '+%Y-%m-%d %H:%M:%S %Z'
    fi
  else
    print -r -- "none"
  fi
}

_nightwatch_caffeinate_running() {
  local pid
  pid="$(_nightwatch_state_get caffeinate_pid 2>/dev/null)"
  _nightwatch_pid_is "$pid" caffeinate && return 0

  # Fallback only over THIS user's processes, so another user's caffeinate can
  # never be mistaken for ours.
  pgrep -U "$(id -u)" -f 'caffeinate -dimsu|caffeinate -imsu' >/dev/null 2>&1
}

_nightwatch_stop_caffeinate() {
  local pid killed=0
  pid="$(_nightwatch_state_get caffeinate_pid 2>/dev/null)"

  # Only signal the tracked pid if it is still actually a caffeinate (guards
  # against the kernel having recycled the pid for an unrelated process).
  if _nightwatch_pid_is "$pid" caffeinate; then
    kill "$pid" 2>/dev/null && killed=1
  fi

  # Recovery sweep only when we lost the pid (e.g. state cleared while a
  # caffeinate we started is still running). Scoped to this user's processes so
  # the blast radius can never reach another account.
  if (( ! killed )); then
    pkill -U "$(id -u)" -f 'caffeinate -dimsu' >/dev/null 2>&1 || true
    pkill -U "$(id -u)" -f 'caffeinate -imsu' >/dev/null 2>&1 || true
  fi

  _nightwatch_state_rm caffeinate_pid
  _nightwatch_state_rm caffeinate_flags
}

_nightwatch_start_caffeinate() {
  _nightwatch_stop_caffeinate

  # `&!` = background + disown (the correct zsh idiom); nohup keeps it ignoring
  # SIGHUP and detaches stdio. Together the process survives the shell exiting.
  nohup caffeinate "$@" >/dev/null 2>&1 &!
  local pid=$!

  _nightwatch_state_set caffeinate_pid "$pid"
  _nightwatch_state_set caffeinate_flags "$*"
}

_nightwatch_stop_watchdog() {
  local pid
  pid="$(_nightwatch_state_get watchdog_pid 2>/dev/null)"

  # Never signal ourselves, and only kill the pid if it is still our watchdog.
  if [[ "$pid" != "$$" ]] && _nightwatch_pid_is "$pid" _nightwatch_watchdog; then
    kill "$pid" 2>/dev/null || true
  fi

  _nightwatch_state_rm watchdog_pid
}

# Snapshot the process table, tagging processes that belong to a coding agent
# (Codex/Claude) or to a work child spawned by one. Output is TSV:
#   pid <tab> cpu_centiseconds <tab> stat <tab> label <tab> command
_nightwatch_snapshot() {
  ps -axo pid=,ppid=,stat=,time=,command= | awk '
    function cpu_cs(value, parts, dayparts, n, days, total) {
      days = 0
      if (index(value, "-") > 0) {
        split(value, dayparts, "-")
        days = dayparts[1] + 0
        value = dayparts[2]
      }

      n = split(value, parts, ":")
      if (n == 3) {
        total = (parts[1] * 3600) + (parts[2] * 60) + parts[3]
      } else if (n == 2) {
        total = (parts[1] * 60) + parts[2]
      } else {
        total = value + 0
      }

      total += days * 86400
      return int((total * 100) + 0.5)
    }

    function ignored(command) {
      if (command ~ /nightwatch\.zsh/) return 1
      if (command ~ /ps -axo pid=.*ppid=.*stat=.*time=.*command/) return 1
      if (command ~ /browser_crashpad_handler/) return 1
      if (command ~ /chrome_crashpad_handler/) return 1
      if (command ~ /--type=gpu-process/) return 1
      if (command ~ /--utility-sub-type=network\.mojom\.NetworkService/) return 1
      if (command ~ /--utility-sub-type=audio\.mojom\.AudioService/) return 1
      if (command ~ /--utility-sub-type=video_capture\.mojom\.VideoCaptureService/) return 1
      if (command ~ /--utility-sub-type=storage\.mojom\.StorageService/) return 1
      if (command ~ /caffeinate /) return 1
      return 0
    }

    function root_label(command) {
      if (command ~ /\/Applications\/Codex\.app\/Contents\/Resources\/codex app-server/) return "Codex Desktop"
      if (command ~ /\/Applications\/Codex\.app\/Contents\/Resources\/cua_node\/bin\/node/) return "Codex Desktop"
      if (command ~ /\/Applications\/Codex\.app\/.*\/Codex \(Renderer\)/) return "Codex Desktop"
      if (command ~ /\/opt\/homebrew\/bin\/codex app-server/) return "Codex Desktop"
      if (command ~ /@openai\/codex/) return "Codex Desktop"
      if (command ~ /\/Applications\/Claude\.app\/Contents\/MacOS\/Claude$/) return "Claude Desktop"
      if (command ~ /\/Applications\/Claude\.app\/.*\/Claude Helper \(Renderer\)/) return "Claude Desktop"
      if (command ~ /\/Applications\/Claude\.app\/Contents\/Helpers\/disclaimer/) return "Claude Desktop"
      if (command ~ /claude-agent-sdk/) return "Claude agent"
      if (command ~ /(^|\/)claude( |$)/) return "Claude CLI"
      if (command ~ /\/\.local\/bin\/claude( |$)/) return "Claude CLI"
      return ""
    }

    function work_child(command) {
      if (command ~ /(^|\/)(git|node|npm|pnpm|yarn|bun|python|python3|pytest|uv|uvx|cargo|rustc|go|make|cmake|xcodebuild|swift|ruby|bundle|rspec|deno|docker|gh|curl|wget|rg|semgrep|codeql)( |$)/) return 1
      if (command ~ /\/bin\/(zsh|sh|bash) -[lc]/) return 1
      return 0
    }

    function agent_ancestor(pid, seen, parent) {
      delete seen
      while (pid in parent_pid) {
        parent = parent_pid[pid]
        if (parent in root) return parent
        if (parent <= 1 || (parent in seen)) return 0
        seen[parent] = 1
        pid = parent
      }
      return 0
    }

    {
      pid = $1
      ppid = $2
      stat = $3
      cpu = $4
      command = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", command)

      parent_pid[pid] = ppid
      process_stat[pid] = stat
      process_cpu[pid] = cpu_cs(cpu)
      process_command[pid] = command

      if (!ignored(command)) {
        label = root_label(command)
        if (label != "") root[pid] = label
      }
    }

    END {
      for (pid in process_command) {
        command = process_command[pid]
        if (ignored(command)) continue

        label = ""
        if (pid in root) {
          label = root[pid]
        } else {
          ancestor = agent_ancestor(pid)
          if (ancestor && work_child(command)) label = root[ancestor] " child"
        }

        if (label != "") {
          gsub(/\t/, " ", command)
          # Strip control/escape bytes so a hostile argv cannot inject terminal
          # escape sequences when this command line is later printed by status.
          gsub(/[^[:print:]]/, " ", command)
          if (length(command) > 180) command = substr(command, 1, 177) "..."
          printf "%s\t%s\t%s\t%s\t%s\n", pid, process_cpu[pid], process_stat[pid], label, command
        }
      }
    }
  '
}

# Compare two snapshots. Report (and return 0) if any agent process is new,
# burned >= NIGHTWATCH_CPU_DELTA_CS centiseconds of CPU since the last snapshot,
# or is currently running. Existence alone is NOT activity - an idle agent at a
# prompt accrues no CPU and does not keep the machine awake.
_nightwatch_detect_activity() {
  local previous current reason
  previous="$(_nightwatch_state_path previous.tsv)"
  current="$(_nightwatch_state_path current.tsv)"

  _nightwatch_snapshot > "$current"

  if [[ ! -f "$previous" ]]; then
    mv "$current" "$previous"
    return 1
  fi

  reason="$(
    awk -F '\t' -v threshold="$NIGHTWATCH_CPU_DELTA_CS" '
      NR == FNR {
        previous_cpu[$1] = $2
        next
      }

      {
        pid = $1
        cpu = $2
        stat = $3
        label = $4
        command = $5

        if (!(pid in previous_cpu)) {
          print "new " label " process pid " pid ": " command
          found = 1
          exit
        }

        delta = cpu - previous_cpu[pid]
        if (delta >= threshold) {
          printf "%s active pid %s: +%.2fs CPU: %s\n", label, pid, delta / 100, command
          found = 1
          exit
        }

        if (stat ~ /^R/ && delta > 0) {
          printf "%s running pid %s: %s\n", label, pid, command
          found = 1
          exit
        }
      }
    ' "$previous" "$current"
  )"

  mv "$current" "$previous"

  if [[ -n "$reason" ]]; then
    print -r -- "$reason"
    return 0
  fi

  return 1
}

_nightwatch_clear_auto_state() {
  _nightwatch_state_rm previous.tsv
  _nightwatch_state_rm current.tsv
  _nightwatch_state_rm mode
  _nightwatch_state_rm phase
  _nightwatch_state_rm deadline_at
  _nightwatch_state_rm idle_after
  _nightwatch_state_rm interval
  _nightwatch_state_rm started_at
  _nightwatch_state_rm last_active_at
  _nightwatch_state_rm last_reason
}

# Map the current state to a short status string for the optional notify hook.
_nightwatch_status_label() {
  local mode phase
  mode="$(_nightwatch_state_get mode 2>/dev/null || print -r -- off)"
  phase="$(_nightwatch_state_get phase 2>/dev/null || print -r -- off)"

  if _nightwatch_caffeinate_running; then
    case "$mode:$phase" in
      away:remote-ready) print -r -- "ready" ;;
      away:*)            print -r -- "away" ;;
      goal:*)            print -r -- "goal" ;;
      manual:timed)      print -r -- "timed" ;;
      *)                 print -r -- "on" ;;
    esac
  else
    print -r -- "off"
  fi
}

# Call the user's optional `nightwatch_notify` hook, if defined. Runs on the
# precmd path in the user's shell, so emulate to keep the helpers it reaches
# (which use `<->`/pattern matching) deterministic regardless of their options.
_nightwatch_emit() {
  emulate -L zsh
  (( $+functions[nightwatch_notify] )) && nightwatch_notify "$(_nightwatch_status_label)"
  return 0
}

_nightwatch_watchdog() {
  emulate -L zsh

  local mode deadline idle_after interval now last_active idle_for reason phase sleep_pid bt
  mode="$1"
  deadline="$2"
  idle_after="$3"
  interval="$4"
  sleep_pid=""

  # Run sleep as a background job and `wait` on it so an incoming TERM/INT/HUP
  # interrupts immediately and the trap fires; a foreground `sleep` would defer
  # the trap until the full interval elapsed, leaving the watchdog alive for up
  # to $interval seconds after `sleepy`.
  trap '[[ -n "$sleep_pid" ]] && kill "$sleep_pid" 2>/dev/null; _nightwatch_stop_caffeinate; _nightwatch_log "watchdog stopped"; exit 0' TERM INT HUP

  now="$(_nightwatch_now)"
  last_active="$now"
  phase="full"

  _nightwatch_state_set mode "$mode"
  _nightwatch_state_set phase "$phase"
  _nightwatch_state_set started_at "$now"
  _nightwatch_state_set deadline_at "$deadline"
  _nightwatch_state_set idle_after "$idle_after"
  _nightwatch_state_set interval "$interval"
  _nightwatch_state_set last_active_at "$last_active"
  _nightwatch_state_set last_reason "watchdog start grace"
  _nightwatch_snapshot > "$(_nightwatch_state_path previous.tsv)"
  _nightwatch_log "watchdog started mode=$mode deadline=$deadline idle_after=$idle_after interval=$interval"

  while true; do
    sleep "$interval" &
    sleep_pid=$!
    wait "$sleep_pid" 2>/dev/null
    sleep_pid=""
    now="$(_nightwatch_now)"

    if reason="$(_nightwatch_detect_activity)"; then
      last_active="$now"
      _nightwatch_state_set last_active_at "$last_active"
      _nightwatch_state_set last_reason "$reason"
      continue
    fi

    idle_for=$(( now - last_active ))
    _nightwatch_state_set last_reason "no Codex Desktop, Claude Desktop, or Claude CLI activity detected"

    if [[ "$mode" == "goal" ]]; then
      if (( idle_for >= idle_after )); then
        _nightwatch_log "goal mode quiet for ${idle_for}s; sleeping"
        _nightwatch_stop_caffeinate
        _nightwatch_clear_auto_state
        _nightwatch_state_set mode "off"
        _nightwatch_state_set phase "off"
        _nightwatch_state_set last_reason "goal quiet for $(_nightwatch_format_duration "$idle_for"); Mac can sleep"
        _nightwatch_state_rm watchdog_pid
        exit 0
      fi
      continue
    fi

    if [[ "$mode" == "away" ]]; then
      phase="$(_nightwatch_state_get phase 2>/dev/null || print -r -- full)"

      if [[ "$phase" == "full" && "$idle_for" -ge "$idle_after" ]]; then
        if bt="$(_nightwatch_backstop_t "$deadline")"; then
          _nightwatch_start_caffeinate -imsu -t "$bt"
        else
          _nightwatch_start_caffeinate -imsu
        fi
        _nightwatch_state_set phase "remote-ready"
        _nightwatch_state_set last_reason "agent work quiet; display may sleep, network stays reachable"
        _nightwatch_log "away mode switched to remote-ready"
      fi

      if (( deadline > 0 && now >= deadline && idle_for >= idle_after )); then
        _nightwatch_log "away mode deadline reached and quiet for ${idle_for}s; sleeping"
        _nightwatch_stop_caffeinate
        _nightwatch_clear_auto_state
        _nightwatch_state_set mode "off"
        _nightwatch_state_set phase "off"
        _nightwatch_state_set last_reason "away window ended; Mac can sleep"
        _nightwatch_state_rm watchdog_pid
        exit 0
      fi
    fi
  done
}

_nightwatch_start_auto() {
  local mode deadline idle_after interval now bt
  mode="$1"
  deadline="$2"
  idle_after="$3"
  interval="$4"

  _nightwatch_stop_watchdog
  # Backstop away mode only: its watchdog sleeps at the deadline, so a -t bounded
  # to deadline+grace aligns with intended behavior. goal mode stays awake purely
  # by activity (no deadline-driven sleep), so a -t there could sleep the Mac
  # mid-work if the watchdog outlived it.
  if [[ "$mode" == "away" ]] && bt="$(_nightwatch_backstop_t "$deadline")"; then
    _nightwatch_start_caffeinate -dimsu -t "$bt"
  else
    _nightwatch_start_caffeinate -dimsu
  fi

  now="$(_nightwatch_now)"
  _nightwatch_state_set mode "$mode"
  _nightwatch_state_set phase "full"
  _nightwatch_state_set started_at "$now"
  _nightwatch_state_set deadline_at "$deadline"
  _nightwatch_state_set idle_after "$idle_after"
  _nightwatch_state_set interval "$interval"
  _nightwatch_state_set last_active_at "$now"
  _nightwatch_state_set last_reason "watchdog starting"

  nohup /bin/zsh -lc "source ${(q)NIGHTWATCH_SCRIPT}; _nightwatch_watchdog ${(q)mode} ${(q)deadline} ${(q)idle_after} ${(q)interval}" >/dev/null 2>&1 &!
  local pid=$!
  _nightwatch_state_set watchdog_pid "$pid"
}

_nightwatch_usage() {
  cat <<'EOF'
nightwatch keep-awake commands:
  awake                 Keep the Mac fully awake until sleepy.
  awake 2h              Keep the Mac fully awake for a fixed duration.
  awake-goal            Keep awake while Codex/Claude work is active; sleep after quiet.
  awake-away 8h         Keep awake now, then remote-ready until the away window ends.
  sleepy                Stop all keep-awake/watchdog modes.
  awake-status          Show current mode, reason, and timers.

Options:
  awake-goal --idle 10m --interval 30s [--max 4h]
  awake-away 4h --idle 15m --interval 60s
EOF
}

awake() {
  emulate -L zsh
  local seconds deadline

  if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    _nightwatch_usage
    return 0
  fi

  _nightwatch_stop_watchdog
  _nightwatch_stop_caffeinate
  _nightwatch_clear_auto_state

  if [[ -n "${1:-}" ]]; then
    seconds="$(_nightwatch_duration_seconds "$1")" || return 1
    deadline=$(( $(_nightwatch_now) + seconds ))
    _nightwatch_start_caffeinate -dimsu -t "$seconds"
    _nightwatch_state_set mode "manual"
    _nightwatch_state_set phase "timed"
    _nightwatch_state_set deadline_at "$deadline"
    _nightwatch_state_set last_reason "manual timed awake"
    echo "Keep-awake enabled for $(_nightwatch_format_duration "$seconds")."
  else
    _nightwatch_start_caffeinate -dimsu
    _nightwatch_state_set mode "manual"
    _nightwatch_state_set phase "full"
    _nightwatch_state_set deadline_at "0"
    _nightwatch_state_set last_reason "manual awake"
    echo "Keep-awake enabled."
  fi

  _nightwatch_emit
}

awake-goal() {
  emulate -L zsh
  local idle_after interval max_seconds deadline now arg
  # Normalize the env-var defaults through the same validator the flags use, so
  # a value like 10m works and nothing unvalidated ever reaches arithmetic.
  idle_after="$(_nightwatch_duration_seconds "$NIGHTWATCH_IDLE_SECONDS")" || return 1
  interval="$(_nightwatch_duration_seconds "$NIGHTWATCH_INTERVAL_SECONDS")" || return 1
  max_seconds=0

  while (( $# > 0 )); do
    arg="$1"
    case "$arg" in
      --help|-h)
        _nightwatch_usage
        return 0
        ;;
      --idle)
        shift
        idle_after="$(_nightwatch_duration_seconds "$1")" || return 1
        ;;
      --idle=*)
        idle_after="$(_nightwatch_duration_seconds "${arg#--idle=}")" || return 1
        ;;
      --interval)
        shift
        interval="$(_nightwatch_duration_seconds "$1")" || return 1
        ;;
      --interval=*)
        interval="$(_nightwatch_duration_seconds "${arg#--interval=}")" || return 1
        ;;
      --max)
        shift
        max_seconds="$(_nightwatch_duration_seconds "$1")" || return 1
        ;;
      --max=*)
        max_seconds="$(_nightwatch_duration_seconds "${arg#--max=}")" || return 1
        ;;
      *)
        max_seconds="$(_nightwatch_duration_seconds "$arg")" || return 1
        ;;
    esac
    shift
  done

  now="$(_nightwatch_now)"
  deadline=0
  (( max_seconds > 0 )) && deadline=$(( now + max_seconds ))

  _nightwatch_start_auto "goal" "$deadline" "$idle_after" "$interval"
  echo "Goal-awake enabled. It will sleep after $(_nightwatch_format_duration "$idle_after") of Codex/Claude quiet."
  _nightwatch_emit
}

awake-away() {
  emulate -L zsh
  local idle_after interval away_seconds deadline arg duration_seen
  idle_after="$(_nightwatch_duration_seconds "$NIGHTWATCH_IDLE_SECONDS")" || return 1
  interval="$(_nightwatch_duration_seconds "$NIGHTWATCH_INTERVAL_SECONDS")" || return 1
  away_seconds=28800
  duration_seen=0

  while (( $# > 0 )); do
    arg="$1"
    case "$arg" in
      --help|-h)
        _nightwatch_usage
        return 0
        ;;
      --idle)
        shift
        idle_after="$(_nightwatch_duration_seconds "$1")" || return 1
        ;;
      --idle=*)
        idle_after="$(_nightwatch_duration_seconds "${arg#--idle=}")" || return 1
        ;;
      --interval)
        shift
        interval="$(_nightwatch_duration_seconds "$1")" || return 1
        ;;
      --interval=*)
        interval="$(_nightwatch_duration_seconds "${arg#--interval=}")" || return 1
        ;;
      *)
        if (( duration_seen )); then
          print -u2 "Only one away duration is supported."
          return 1
        fi
        away_seconds="$(_nightwatch_duration_seconds "$arg")" || return 1
        duration_seen=1
        ;;
    esac
    shift
  done

  deadline=$(( $(_nightwatch_now) + away_seconds ))

  _nightwatch_start_auto "away" "$deadline" "$idle_after" "$interval"
  echo "Away-awake enabled for $(_nightwatch_format_duration "$away_seconds"). After work quiets, display may sleep but remote access stays ready."
  _nightwatch_emit
}

sleepy() {
  emulate -L zsh
  _nightwatch_stop_watchdog

  if _nightwatch_caffeinate_running; then
    _nightwatch_stop_caffeinate
    echo "Keep-awake disabled. Mac can sleep now."
  else
    echo "Keep-awake was already off."
  fi

  _nightwatch_clear_auto_state
  _nightwatch_state_set mode "off"
  _nightwatch_state_set phase "off"
  _nightwatch_state_set last_reason "sleepy called"
  _nightwatch_emit
}

awake-status() {
  emulate -L zsh
  local now mode phase started deadline idle_after last_active last_reason flags watchdog_pid caffeinate_pid
  now="$(_nightwatch_now)"
  mode="$(_nightwatch_state_get mode 2>/dev/null || print -r -- off)"
  phase="$(_nightwatch_state_get phase 2>/dev/null || print -r -- off)"
  started="$(_nightwatch_state_get started_at 2>/dev/null || print -r -- 0)"
  deadline="$(_nightwatch_state_get deadline_at 2>/dev/null || print -r -- 0)"
  idle_after="$(_nightwatch_state_get idle_after 2>/dev/null || print -r -- "$NIGHTWATCH_IDLE_SECONDS")"
  last_active="$(_nightwatch_state_get last_active_at 2>/dev/null || print -r -- 0)"
  last_reason="$(_nightwatch_state_get last_reason 2>/dev/null || print -r -- "no state")"
  flags="$(_nightwatch_state_get caffeinate_flags 2>/dev/null || print -r -- "")"
  watchdog_pid="$(_nightwatch_state_get watchdog_pid 2>/dev/null || print -r -- "")"
  caffeinate_pid="$(_nightwatch_state_get caffeinate_pid 2>/dev/null || print -r -- "")"

  if _nightwatch_caffeinate_running; then
    echo "Keep-awake is ON."
  else
    echo "Keep-awake is OFF."
  fi

  echo "mode: $mode"
  echo "phase: $phase"
  [[ -n "$flags" ]] && echo "caffeinate: $flags pid=${caffeinate_pid:-unknown}"
  [[ -n "$watchdog_pid" ]] && echo "watchdog: pid=$watchdog_pid"
  [[ "$started" == <-> && "$started" -gt 0 ]] && echo "started: $(_nightwatch_time_label "$started")"

  if [[ "$last_active" == <-> && "$last_active" -gt 0 ]]; then
    echo "idle: $(_nightwatch_format_duration "$(( now - last_active ))") / threshold $(_nightwatch_format_duration "$idle_after")"
  fi

  if [[ "$deadline" == <-> && "$deadline" -gt 0 ]]; then
    if (( now < deadline )); then
      echo "window remaining: $(_nightwatch_format_duration "$(( deadline - now ))")"
    else
      echo "window remaining: elapsed; waiting for activity to quiet"
    fi
    echo "window ends: $(_nightwatch_time_label "$deadline")"
  fi

  echo "reason: $last_reason"
  _nightwatch_emit
}

# Install a per-prompt refresh of the notify hook so background state changes
# (e.g. the watchdog dropping to remote-ready) reach your badge/status segment.
# Only registered when you have defined `nightwatch_notify` before sourcing.
if [[ -o interactive ]] && (( $+functions[nightwatch_notify] )); then
  autoload -Uz add-zsh-hook
  add-zsh-hook -d precmd _nightwatch_emit 2>/dev/null || true
  add-zsh-hook precmd _nightwatch_emit
fi
