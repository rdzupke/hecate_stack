#!/usr/bin/env bash
# ─────────────────────────────────────────────
# borg-backup.sh — recurring backup direct to Hyperion
# Run after borg-seed.sh + rsync have completed.
# Schedule via cron.
# ─────────────────────────────────────────────
set -euo pipefail

# ── CLI Arguments ──────────────────────────────
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n)
      DRY_RUN=true
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

# ── Retention policy ───────────────────────────
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6

# ─────────────────────────────────────────────
log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Notify! push notifications ─────────────────
# Credentials live outside the repo, in a file containing:
#   NOTIFY_DEVICE_ID=...   (device or GRP group id)
#   NOTIFY_TOKEN=...
#   NOTIFY_ICON_URL=...    (optional; overrides the default icon below)
# If the file is missing, notifications are silently skipped.
NOTIFY_CREDS_FILE="$HOME/.notify-credentials"
NOTIFY_URL="https://push.getnotifyapp.com/notify-json"
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
    [[ -n "${NOTIFY_DEVICE_ID:-}" && -n "${NOTIFY_TOKEN:-}" ]] || exit 0
    payload="$(python3 -c 'import json,sys; print(json.dumps({"title": sys.argv[1], "text": sys.argv[2], "groupType": sys.argv[3], "iconUrl": sys.argv[4]}))' \
      "$title" "$text" "$NOTIFY_GROUP_TYPE" "${NOTIFY_ICON_URL:-$NOTIFY_ICON_URL_DEFAULT}")"
    curl -fsS --max-time 10 --retry 2 -X POST \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$NOTIFY_URL/$NOTIFY_DEVICE_ID?token=$NOTIFY_TOKEN" > /dev/null
  ) || log "  WARNING: failed to send Notify! notification"
  return 0
}

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
  exit $rc
}
trap on_exit EXIT

notify "Hecate backup started" "Archive $ARCHIVE_NAME"

if [[ "$DRY_RUN" == "true" ]]; then
  log "=== RUNNING IN DRY RUN MODE ==="
  log "Stacks will be stopped and restarted, but Borg backup/prune/compact will be skipped."
fi

# ── Borg Environment Setup ─────────────────────
if [[ "$DRY_RUN" == "false" ]]; then
  if [[ ! -f "$BORG_PASSPHRASE_FILE" ]]; then
    log "ERROR: Passphrase file not found at $BORG_PASSPHRASE_FILE"
    exit 1
  fi
  export BORG_PASSPHRASE
  BORG_PASSPHRASE="$(cat "$BORG_PASSPHRASE_FILE")"
  export BORG_RSH="ssh -i $HOME/.ssh/borg_backup_key"
  export BORG_REMOTE_PATH="/opt/homebrew/bin/borg"
  export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
fi

# ── Docker Desktop check ───────────────────────
if ! docker info > /dev/null 2>&1; then
  log "ERROR: Docker Desktop is not running. Exiting."
  exit 1
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
    stack_down "$name"
    STACKS_STOPPED+=("$name")
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
  borg create \
    --compression zstd,3 \
    --stats \
    --filter AME \
    "$REMOTE_REPO::$ARCHIVE_NAME" \
    "$SOURCE_DIR" 2>&1 | tee "$BORG_LOG"

  # "This archive:  <orig>  <compressed>  <dedup>" line from --stats
  ARCHIVE_STATS="$(grep -E '^This archive:' "$BORG_LOG" | head -1 | sed -E 's/ +/ /g' || true)"
  rm -f "$BORG_LOG"

  log "Archive created successfully."
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
  borg prune \
    --keep-daily="$KEEP_DAILY" \
    --keep-weekly="$KEEP_WEEKLY" \
    --keep-monthly="$KEEP_MONTHLY" \
    --list \
    "$REMOTE_REPO"

  CURRENT_STEP="borg compact (archive was created, stacks restarted)"
  log "Compacting repo..."
  borg compact "$REMOTE_REPO"

  log "Backup complete."
  notify "Hecate backup complete" "$ARCHIVE_NAME in $(( SECONDS - START_SECONDS ))s. ${#RUNNING_STACKS[@]} stack(s) restarted. ${ARCHIVE_STATS:-No stats available}"
fi
