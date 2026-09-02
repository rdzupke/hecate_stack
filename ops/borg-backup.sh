#!/usr/bin/env bash
# ─────────────────────────────────────────────
# borg-backup-hecate.sh — recurring backup direct to Hyperion
# Run after borg-seed-hecate.sh + rsync have completed.
# Schedule via cron.
# ─────────────────────────────────────────────
set -euo pipefail

# ── Configuration ─────────────────────────────
REMOTE_REPO="rdzupke@100.68.245.122:/Volumes/My Book for Mac/borg-backup-hecate"
SOURCE_DIR="/Users/rdzupke/git/rdzupke/hecate_stack"
STACK_ROOT="$SOURCE_DIR"
ARCHIVE_NAME="hecate-$(date +%Y-%m-%dT%H:%M)"
BORG_PASSPHRASE_FILE="$HOME/.borg-passphrase"

# ── Stack directories ──────────────────────────
STACKS=(
  "airtrail"
  "audiobookshelf"
  "beszel"
  "cloudflared"
  "grocy"
  "homebox-sam"
  "immich"
  "linkwarden"
  "lubelogger"
  "mealie"
  "memos"
  "nginxpm"
  "open-webui"
  "paperless"
  "romm"
  "termix"
  "uptime-kuma"
  "vaultwarden"
  "vestaboard"
  "whiskers"
  "yamtrack"
)

# ── Retention policy ───────────────────────────
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6

# ─────────────────────────────────────────────
export BORG_PASSPHRASE
BORG_PASSPHRASE="$(cat "$BORG_PASSPHRASE_FILE")"
export BORG_RSH="ssh -i $HOME/.ssh/borg_backup_key"
export BORG_REMOTE_PATH="/opt/homebrew/bin/borg"
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Docker Desktop check ───────────────────────
if ! docker info > /dev/null 2>&1; then
  log "ERROR: Docker Desktop is not running. Exiting."
  exit 1
fi

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

# ── Stop all stacks ────────────────────────────
log "Stopping all stacks..."
for name in "${STACKS[@]}"; do
  stack_down "$name"
  STACKS_STOPPED+=("$name")
done

# ── Verify containers are stopped ─────────────
log "Verifying all containers stopped..."
sleep 3
RUNNING=$(docker ps --format '{{.Names}}' | grep -v "^$" || true)
if [[ -n "$RUNNING" ]]; then
  log "WARNING: the following containers are still running:"
  echo "$RUNNING"
fi

# ── Create archive ─────────────────────────────
log "Creating remote archive $ARCHIVE_NAME..."
borg create \
  --compression zstd,3 \
  --stats \
  --filter AME \
  "$REMOTE_REPO::$ARCHIVE_NAME" \
  "$SOURCE_DIR"

log "Archive created successfully."

# ── Restart stacks ─────────────────────────────
log "Restarting all stacks..."
for name in "${STACKS[@]}"; do
  stack_up "$name"
done
STACKS_STOPPED=()
trap - EXIT

# ── Prune + compact ────────────────────────────
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
