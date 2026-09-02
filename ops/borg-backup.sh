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

# ── Ensure containers restart even if script fails ──
STACKS_STOPPED=()
cleanup() {
  if [[ ${#STACKS_STOPPED[@]} -gt 0 ]]; then
    log "Running cleanup — restarting stopped stacks..."
    for name in "${STACKS_STOPPED[@]}"; do
      stack_up "$name" || log "  WARNING: failed to restart $name"
    done
  fi
}
trap cleanup EXIT

# ── Discover active stacks ─────────────────────
log "Detecting currently running stacks..."
RUNNING_STACKS=()
read -r -a RUNNING_STACKS <<< "$(get_running_stacks)"

if [[ ${#RUNNING_STACKS[@]} -eq 0 ]]; then
  log "No running stacks detected."
else
  log "Found ${#RUNNING_STACKS[@]} running stack(s): ${RUNNING_STACKS[*]}"
fi

# ── Stop running stacks ────────────────────────
if [[ ${#RUNNING_STACKS[@]} -gt 0 ]]; then
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
  log "Creating remote archive $ARCHIVE_NAME..."
  borg create \
    --compression zstd,3 \
    --stats \
    --filter AME \
    "$REMOTE_REPO::$ARCHIVE_NAME" \
    "$SOURCE_DIR"

  log "Archive created successfully."
fi

# ── Restart previously running stacks ──────────
if [[ ${#RUNNING_STACKS[@]} -gt 0 ]]; then
  log "Restarting previously running stacks..."
  for name in "${RUNNING_STACKS[@]}"; do
    stack_up "$name"
  done
fi
STACKS_STOPPED=()
trap - EXIT

# ── Prune + compact ────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY RUN] Skipping Borg prune and compact."
  log "Dry run complete. All previously running stacks have been restarted."
else
  log "Pruning old archives..."
  borg prune \
    --keep-daily="$KEEP_DAILY" \
    --keep-weekly="$KEEP_WEEKLY" \
    --keep-monthly="$KEEP_MONTHLY" \
    --list \
    "$REMOTE_REPO"

  log "Compacting repo..."
  borg compact "$REMOTE_REPO"

  log "Backup complete."
fi
