#!/usr/bin/env bash
# ─────────────────────────────────────────────
# borg-backup.sh — recurring backup direct to Hyperion
# Run after borg-seed.sh + rsync have completed.
# Scheduled with launchd: xyz.zupke.borg-backup.plist (see README.md).
#
# The script runs in two roles. The launcher (what you invoke) checks
# prerequisites, starts a detached worker, and follows its log. The worker
# does the backup and keeps running if your connection drops.
# ─────────────────────────────────────────────
set -euo pipefail

# ── CLI Arguments ──────────────────────────────
# --worker and --delay are internal: the launcher passes them to the worker.
DRY_RUN=false
WORKER=false
START_DELAY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n)
      DRY_RUN=true
      ;;
    --worker)
      WORKER=true
      ;;
    --delay=*)
      START_DELAY="${arg#--delay=}"
      ;;
    --help|-h)
      echo "Usage: $0 [--dry-run|-n]"
      echo "  --dry-run, -n   Stop and restart running stacks to test lifecycle without running Borg backup"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg"
      echo "Usage: $0 [--dry-run|-n]"
      exit 1
      ;;
  esac
done

# ── Configuration ─────────────────────────────
REMOTE_REPO="rdzupke@100.68.245.122:/Volumes/My Book for Mac/borg-backup-hecate"
SOURCE_DIR="/Users/rdzupke/git/rdzupke/hecate_stack"
STACK_ROOT="$SOURCE_DIR"
ARCHIVE_NAME="hecate-$(date +%Y-%m-%dT%H:%M)"
BORG_PASSPHRASE_FILE="$HOME/.borg-passphrase"
LOG_DIR="$HOME/Library/Logs/hecate-backup"   # must stay outside SOURCE_DIR
LOCK_FILE="$HOME/.hecate-backup.lock"        # symlink whose target is the worker PID
CLOSE_COUNTDOWN=10   # seconds of warning before closing a relayed session
CLOSE_GRACE=5        # seconds the worker waits so the close reaches the client

# ── Retention policy ───────────────────────────
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6

# ─────────────────────────────────────────────
log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Notify! push notifications ─────────────────
# Credentials live outside the repo, in a file containing:
#   NOTIFY_GROUP_ID=...    (GRP… group id)
#   NOTIFY_TOKEN=...
#   NOTIFY_ICON_URL=...    (optional; overrides the default icon below)
#   HECATE_BACKUP_BEACON_URL=...  (optional; heartbeat pinged after a successful backup)
# If the file is missing, notifications are silently skipped.
NOTIFY_CREDS_FILE="$HOME/.notify-credentials"
NOTIFY_URL="https://push.getnotifyapp.com/notify-group"
NOTIFY_GROUP_TYPE="backups"
NOTIFY_ICON_URL_DEFAULT="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/borg.png"

# notify <title> <text> — best-effort; never fails or blocks the backup.
notify() {
  local title=$1 text=$2
  [[ "$DRY_RUN" == "true" ]] && title="[DRY RUN] $title"
  [[ -f "$NOTIFY_CREDS_FILE" ]] || return 0
  (
    # shellcheck disable=SC1090
    source "$NOTIFY_CREDS_FILE"
    [[ -n "${NOTIFY_GROUP_ID:-}" && -n "${NOTIFY_TOKEN:-}" ]] || exit 0
    # notify-group takes query parameters (a JSON body is rejected with 400)
    curl -fsS --max-time 10 --retry 2 -X POST -G \
      --data-urlencode "token=$NOTIFY_TOKEN" \
      --data-urlencode "title=$title" \
      --data-urlencode "body=$text" \
      --data-urlencode "groupType=$NOTIFY_GROUP_TYPE" \
      --data-urlencode "iconUrl=${NOTIFY_ICON_URL:-$NOTIFY_ICON_URL_DEFAULT}" \
      "$NOTIFY_URL/$NOTIFY_GROUP_ID" > /dev/null
  ) || log "  WARNING: failed to send Notify! notification"
  return 0
}

# ping_beacon — tells the Notify! beacon a backup succeeded. The beacon alerts
# when pings stop arriving. Best-effort, and skipped on dry runs.
ping_beacon() {
  [[ "$DRY_RUN" == "false" && -f "$NOTIFY_CREDS_FILE" ]] || return 0
  (
    # shellcheck disable=SC1090
    source "$NOTIFY_CREDS_FILE"
    [[ -n "${HECATE_BACKUP_BEACON_URL:-}" ]] || exit 0
    curl -fsS --max-time 10 --retry 3 "$HECATE_BACKUP_BEACON_URL" > /dev/null
  ) || log "  WARNING: failed to ping the Notify! beacon"
  return 0
}

# ── Borg environment ───────────────────────────
setup_borg_env() {
  export BORG_PASSPHRASE
  BORG_PASSPHRASE="$(cat "$BORG_PASSPHRASE_FILE")" || return 1
  # BatchMode: ssh must fail rather than prompt (the worker has no terminal).
  # ConnectTimeout: fail promptly when Hyperion is offline.
  export BORG_RSH="ssh -i $HOME/.ssh/borg_backup_key -o BatchMode=yes -o ConnectTimeout=15"
  export BORG_REMOTE_PATH="/opt/homebrew/bin/borg"
  export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
  # Exit status 1 = warnings, 2 and up = errors (check_borg_status relies on it).
  export BORG_EXIT_CODES=legacy
}

# ── Lock (one backup at a time) ────────────────
lock_pid() { readlink "$LOCK_FILE" 2>/dev/null || true; }

backup_running() {
  local pid
  pid="$(lock_pid)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Creating a symlink is atomic. A lock left by a dead process is replaced.
acquire_lock() {
  ln -s "$$" "$LOCK_FILE" 2>/dev/null && return 0
  backup_running && return 1
  rm -f "$LOCK_FILE"
  ln -s "$$" "$LOCK_FILE" 2>/dev/null
}

# ── Launcher ───────────────────────────────────
# Sets SESSION_TYPE and CLIENT_IP from SSH_CONNECTION. "relayed" means the SSH
# client is on this host, e.g. a Termix container (seen as 127.0.0.1 on macOS).
classify_session() {
  CLIENT_IP=""
  SESSION_TYPE="local"
  [[ -n "${SSH_CONNECTION:-}" ]] || return 0
  local server_ip
  read -r CLIENT_IP _ server_ip _ <<< "$SSH_CONNECTION"
  case "$CLIENT_IP" in
    127.*|::1|::ffff:127.*|"$server_ip") SESSION_TYPE="relayed" ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|fd7a:115c:a1e0:*) SESSION_TYPE="tailnet" ;;
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|fe80:*) SESSION_TYPE="LAN" ;;
    *) SESSION_TYPE="other remote" ;;
  esac
}

# Prints the PID of this session's login shell: the ancestor whose parent is sshd.
login_shell_pid() {
  local pid=$PPID parent
  while [[ "$pid" -gt 1 ]]; do
    [[ "$(ps -o comm= -p "$pid")" != *sshd* ]] || return 1
    parent="$(ps -o ppid= -p "$pid" | tr -d ' ')"
    [[ -n "$parent" && "$parent" -gt 1 ]] || return 1
    if [[ "$(ps -o comm= -p "$parent")" == *sshd* ]]; then
      echo "$pid"
      return 0
    fi
    pid=$parent
  done
  return 1
}

# Confirms Hyperion is reachable and the repo opens, using a read-only listing.
# Runs in a subshell so the passphrase stays out of the launcher's environment.
check_repo() {
  local output
  if ! output="$(setup_borg_env && borg list --last 1 "$REMOTE_REPO" 2>&1 < /dev/null)"; then
    echo "$output" >&2
    PREFLIGHT_ERROR="Cannot open the Borg repository: $(tail -n 1 <<< "$output")"
    return 1
  fi
}

# Catch obvious failures while the user can still see them, and before any
# stack is stopped.
preflight() {
  if [[ "$DRY_RUN" == "false" ]]; then
    if [[ ! -f "$BORG_PASSPHRASE_FILE" ]]; then
      PREFLIGHT_ERROR="Passphrase file not found at $BORG_PASSPHRASE_FILE"
      return 1
    fi
    if ! command -v borg > /dev/null 2>&1; then
      PREFLIGHT_ERROR="borg is not on PATH"
      return 1
    fi
  fi
  if ! docker info > /dev/null 2>&1; then
    PREFLIGHT_ERROR="Docker Desktop is not running"
    return 1
  fi
  # Last, because it is the only check that needs the network.
  if [[ "$DRY_RUN" == "false" ]]; then
    log "Checking the Borg repository..."
    check_repo || return 1
  fi
}

warn_and_count_down() {
  local log_file=$1 i
  log "WARNING: this SSH session is relayed through this host (client $CLIENT_IP), e.g. by Termix."
  log "The backup stops the containers that carry it, so this session will be closed first."
  log "Termix will be unavailable until the stacks restart, and other Termix terminals will drop."
  log "The backup keeps running. After reconnecting, follow it with:"
  log "  tail -f \"$log_file\""
  log "Press Ctrl-C to cancel."
  trap 'echo; log "Cancelled. Nothing was changed."; exit 130' INT
  for (( i = CLOSE_COUNTDOWN; i > 0; i-- )); do
    printf '\r  Closing this session in %2d seconds... ' "$i"
    sleep 1
  done
  echo
  trap - INT
}

launch() {
  classify_session
  log "Connection: $SESSION_TYPE${CLIENT_IP:+ (client $CLIENT_IP)}"

  if backup_running; then
    log "ERROR: a backup is already running (PID $(lock_pid)). Logs are in $LOG_DIR"
    exit 1
  fi
  if ! preflight; then
    log "ERROR: $PREFLIGHT_ERROR. Exiting."
    notify "Hecate backup FAILED" "Preflight: $PREFLIGHT_ERROR."
    exit 1
  fi

  mkdir -p "$LOG_DIR"
  local log_file
  log_file="$LOG_DIR/backup-$(date +%Y%m%d-%H%M%S).log"

  local close_pid="" delay=0
  if [[ "$SESSION_TYPE" == "relayed" && -t 0 && -t 1 ]]; then
    if [[ -n "${TMUX:-}${STY:-}" ]]; then
      log "Inside tmux/screen, so this session will not be closed."
    elif close_pid="$(login_shell_pid)"; then
      warn_and_count_down "$log_file"
      delay=$CLOSE_GRACE
    else
      log "Could not identify the login shell, so this session will not be closed."
    fi
  fi

  local worker_args=(--worker "--delay=$delay")
  [[ "$DRY_RUN" == "true" ]] && worker_args+=(--dry-run)

  # set -m gives the worker its own process group, so Ctrl-C and hangups here
  # do not reach it; nohup covers SIGHUP as well.
  set -m
  nohup "$BASH" "$0" "${worker_args[@]}" < /dev/null > "$log_file" 2>&1 &
  local worker_pid=$!
  set +m
  ln -sfn "$log_file" "$LOG_DIR/latest.log"

  log "Backup running in the background (PID $worker_pid). Log: $log_file"

  if [[ -n "$close_pid" ]]; then
    sleep 1
    # Only close the session if the worker survived startup.
    if kill -0 "$worker_pid" 2>/dev/null; then
      log "Closing this session now."
      kill -HUP "$close_pid"
      exit 0
    fi
    log "The backup exited early, so this session stays open."
  fi

  log "Following the log. Ctrl-C stops following only; to abort: kill -TERM -- -$worker_pid"
  tail -n +1 -f "$log_file" &
  local tail_pid=$! rc=0
  # shellcheck disable=SC2064
  trap "kill $tail_pid 2>/dev/null; echo; log 'Stopped following. The backup is still running.'; exit 130" INT
  wait "$worker_pid" || rc=$?
  sleep 1   # let tail print the last lines
  kill "$tail_pid" 2>/dev/null || true
  exit "$rc"
}

if [[ "$WORKER" == "false" ]]; then
  launch
fi

# ═══════════════ Worker from here on ═════════════

# ── Exit handling: restart stacks + report failure ──
# Runs on every exit (success or failure). Stacks are always restarted;
# a failure notification is sent if the script exits non-zero.
STACKS_STOPPED=()
CURRENT_STEP="starting up"
START_SECONDS=$SECONDS
on_exit() {
  local rc=$?
  trap - EXIT
  set +e
  local restart_failed=()
  if [[ ${#STACKS_STOPPED[@]} -gt 0 ]]; then
    log "Running cleanup — restarting stopped stacks..."
    for name in "${STACKS_STOPPED[@]}"; do
      stack_up "$name" || { log "  WARNING: failed to restart $name"; restart_failed+=("$name"); }
    done
  fi
  if [[ $rc -ne 0 ]]; then
    local msg="Failed during: $CURRENT_STEP (exit $rc, $(( SECONDS - START_SECONDS ))s)."
    if [[ ${#STACKS_STOPPED[@]} -gt 0 ]]; then
      if [[ ${#restart_failed[@]} -gt 0 ]]; then
        msg+=" Could NOT restart: ${restart_failed[*]}."
      else
        msg+=" Stacks were restarted."
      fi
    fi
    notify "Hecate backup FAILED" "$msg"
  fi
  [[ "$(lock_pid)" == "$$" ]] && rm -f "$LOCK_FILE"
  exit $rc
}

if ! acquire_lock; then
  log "ERROR: a backup is already running (PID $(lock_pid)). Exiting."
  exit 1
fi
trap on_exit EXIT
# Make interruptions exit non-zero, so on_exit reports them as failures.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

log "Worker PID $$. To abort: kill -TERM -- -$$"
sleep "$START_DELAY"

notify "Hecate backup started" "Archive $ARCHIVE_NAME"

if [[ "$DRY_RUN" == "true" ]]; then
  log "=== RUNNING IN DRY RUN MODE ==="
  log "Stacks will be stopped and restarted, but Borg backup/prune/compact will be skipped."
fi

# ── Borg Environment Setup ─────────────────────
if [[ "$DRY_RUN" == "false" ]]; then
  setup_borg_env
fi

# ── Running stacks discovery ───────────────────
get_running_stacks() {
  local running=()
  local dir name running_containers

  shopt -s nullglob
  for dir in "$STACK_ROOT"/*/; do
    dir="${dir%/}"
    name="$(basename "$dir")"

    # Skip non-stack utility directories
    [[ "$name" =~ ^(\.git|ops|dev|setup)$ ]] && continue

    # Ensure it is a compose stack directory
    if [[ ! -x "$dir/prod.sh" && ! -f "$dir/compose.yml" && ! -f "$dir/docker-compose.yml" ]]; then
      continue
    fi

    # Check if there are any running containers for this stack
    running_containers="$(docker ps --filter "label=com.docker.compose.project.working_dir=$dir" -q 2>/dev/null || true)"
    if [[ -z "$running_containers" ]]; then
      running_containers="$(docker ps --filter "label=com.docker.compose.project=$name" -q 2>/dev/null || true)"
    fi

    if [[ -n "$running_containers" ]]; then
      running+=("$name")
    fi
  done
  shopt -u nullglob

  echo "${running[@]}"
}

# ── Stack up/down helpers ──────────────────────
stack_down() {
  local name=$1
  local path="$STACK_ROOT/$name"
  log "Stopping $name..."
  if [[ -x "$path/prod.sh" ]]; then
    (cd "$path" && ./prod.sh down)
  else
    local f
    if [[ -f "$path/compose.yml" ]]; then
      f="$path/compose.yml"
    elif [[ -f "$path/docker-compose.yml" ]]; then
      f="$path/docker-compose.yml"
      log "  TODO: $name still uses docker-compose.yml — standardize to compose.yml"
    else
      log "  WARNING: no compose file found for $name, skipping"
      return 0
    fi
    docker compose -f "$f" down
  fi
}

stack_up() {
  local name=$1
  local path="$STACK_ROOT/$name"
  log "Starting $name..."
  if [[ -x "$path/prod.sh" ]]; then
    (cd "$path" && ./prod.sh)
  else
    local f
    if [[ -f "$path/compose.yml" ]]; then
      f="$path/compose.yml"
    elif [[ -f "$path/docker-compose.yml" ]]; then
      f="$path/docker-compose.yml"
    else
      log "  WARNING: no compose file found for $name, skipping"
      return 0
    fi
    docker compose -f "$f" up -d
  fi
}

# ── Borg exit status ───────────────────────────
# check_borg_status <step> <status> — status 1 means the step finished with
# warnings, which is recorded and tolerated. Anything higher aborts the backup.
WARNING_STEPS=""
check_borg_status() {
  local step=$1 status=$2
  [[ "$status" -ne 0 ]] || return 0
  [[ "$status" -eq 1 ]] || exit "$status"
  log "  WARNING: $step finished with warnings."
  WARNING_STEPS="${WARNING_STEPS:+$WARNING_STEPS, }$step"
}

# ── Discover active stacks ─────────────────────
CURRENT_STEP="discovering running stacks"
log "Detecting currently running stacks..."
RUNNING_STACKS=()
read -r -a RUNNING_STACKS <<< "$(get_running_stacks)"

if [[ ${#RUNNING_STACKS[@]} -eq 0 ]]; then
  log "No running stacks detected."
else
  log "Found ${#RUNNING_STACKS[@]} running stack(s): ${RUNNING_STACKS[*]}"
fi

# ── Record container version checkpoints ───────
if [[ ${#RUNNING_STACKS[@]} -gt 0 ]]; then
  log "Recording container version checkpoints and image digests..."
  python3 "$STACK_ROOT/ops/record-manifest.py" \
    --archive-name "$ARCHIVE_NAME" \
    --stack-root "$STACK_ROOT" || log "  WARNING: Failed to record container version checkpoints"
fi

# ── Stop running stacks ────────────────────────
if [[ ${#RUNNING_STACKS[@]} -gt 0 ]]; then
  CURRENT_STEP="stopping stacks"
  log "Stopping running stacks..."
  for name in "${RUNNING_STACKS[@]}"; do
    # Recorded first, so an interrupted or partial stop is still restarted.
    STACKS_STOPPED+=("$name")
    stack_down "$name"
  done
fi

# ── Verify containers are stopped ─────────────
log "Verifying all containers stopped..."
sleep 3
RUNNING=$(docker ps --format '{{.Names}}' | grep -v "^$" || true)
if [[ -n "$RUNNING" ]]; then
  log "WARNING: the following containers are still running:"
  echo "$RUNNING"
fi

# ── Create archive ─────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY RUN] Skipping Borg archive creation."
else
  CURRENT_STEP="borg create"
  log "Creating remote archive $ARCHIVE_NAME..."
  BORG_LOG="$(mktemp)"
  BORG_STATUS=0
  borg create \
    --compression zstd,3 \
    --stats \
    --filter AME \
    "$REMOTE_REPO::$ARCHIVE_NAME" \
    "$SOURCE_DIR" 2>&1 | tee "$BORG_LOG" || BORG_STATUS=$?

  # "This archive:  <orig>  <compressed>  <dedup>" line from --stats
  ARCHIVE_STATS="$(grep -E '^This archive:' "$BORG_LOG" | head -1 | sed -E 's/ +/ /g' || true)"
  # Borg reports problem files above the --stats block. Keep the first few.
  CREATE_WARNINGS=""
  if [[ "$BORG_STATUS" -eq 1 ]]; then
    CREATE_WARNINGS="$(awk '/^----------/ { exit } NF { print substr($0, 1, 200); if (++n == 3) exit }' "$BORG_LOG" || true)"
  fi
  rm -f "$BORG_LOG"

  check_borg_status "borg create" "$BORG_STATUS"
  log "Archive created."
fi

# ── Restart previously running stacks ──────────
if [[ ${#RUNNING_STACKS[@]} -gt 0 ]]; then
  log "Restarting previously running stacks..."
  CURRENT_STEP="restarting stacks"
  for name in "${RUNNING_STACKS[@]}"; do
    stack_up "$name"
  done
fi
STACKS_STOPPED=()

# ── Prune + compact ────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY RUN] Skipping Borg prune and compact."
  log "Dry run complete. All previously running stacks have been restarted."
  notify "Hecate backup dry run complete" "${#RUNNING_STACKS[@]} stack(s) stopped and restarted in $(( SECONDS - START_SECONDS ))s."
else
  CURRENT_STEP="borg prune (archive was created, stacks restarted)"
  log "Pruning old archives..."
  BORG_STATUS=0
  borg prune \
    --keep-daily="$KEEP_DAILY" \
    --keep-weekly="$KEEP_WEEKLY" \
    --keep-monthly="$KEEP_MONTHLY" \
    --list \
    "$REMOTE_REPO" || BORG_STATUS=$?
  check_borg_status "borg prune" "$BORG_STATUS"

  CURRENT_STEP="borg compact (archive was created, stacks restarted)"
  log "Compacting repo..."
  BORG_STATUS=0
  borg compact "$REMOTE_REPO" || BORG_STATUS=$?
  check_borg_status "borg compact" "$BORG_STATUS"

  SUMMARY="$ARCHIVE_NAME in $(( SECONDS - START_SECONDS ))s. ${#RUNNING_STACKS[@]} stack(s) restarted."
  if [[ -n "$WARNING_STEPS" ]]; then
    log "Backup completed with warnings from: $WARNING_STEPS."
    notify "Hecate backup completed with WARNINGS" "$SUMMARY Warnings from: $WARNING_STEPS. See $LOG_DIR/latest.log${CREATE_WARNINGS:+
$CREATE_WARNINGS}"
  else
    log "Backup complete."
    notify "Hecate backup complete" "$SUMMARY ${ARCHIVE_STATS:-No stats available}"
  fi
  ping_beacon
fi
