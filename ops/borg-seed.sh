#!/usr/bin/env bash
# ─────────────────────────────────────────────
# borg-seed-hecate.sh — one-time initial backup to local disk
# Run manually once. After this, rsync the seed repo to Hyperion,
# then use borg-backup-hecate.sh for all subsequent backups.
# ─────────────────────────────────────────────
set -euo pipefail

# ── Configuration ─────────────────────────────
SEED_REPO="$HOME/borg-seed/hecate"
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

# ─────────────────────────────────────────────
export BORG_PASSPHRASE
BORG_PASSPHRASE="$(cat "$BORG_PASSPHRASE_FILE")"

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

# ── Init repo if needed ────────────────────────
if [[ ! -d "$SEED_REPO" ]]; then
  log "Initializing Borg repo at $SEED_REPO..."
  mkdir -p "$SEED_REPO"
  borg init --encryption=repokey-blake2 "$SEED_REPO"
  log "Repo initialized."
  log ""
  log "*** IMPORTANT: export and save your key ***"
  log "Run: borg key export $SEED_REPO ~/borg-key-hecate.txt"
  log "Store borg-key-hecate.txt somewhere safe (not just on hecate)."
  log ""
fi

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
  log "Proceeding anyway — check these manually after backup."
fi

# ── Create archive ─────────────────────────────
log "Creating archive $ARCHIVE_NAME..."
borg create \
  --compression zstd,3 \
  --stats \
  --list \
  --filter AME \
  "$SEED_REPO::$ARCHIVE_NAME" \
  "$SOURCE_DIR"

log "Archive created successfully."

# ── Restart stacks ─────────────────────────────
log "Restarting all stacks..."
for name in "${STACKS[@]}"; do
  stack_up "$name"
done
STACKS_STOPPED=()
trap - EXIT

# ── Done ───────────────────────────────────────
log ""
log "Seed backup complete."
log ""
log "Next steps:"
log "  1. Export your key if you haven't:"
log "     borg key export $SEED_REPO ~/borg-key-hecate.txt"
log ""
log "  2. Rsync the seed repo to Hyperion (run from hecate):"
log "     rsync -av --progress --append-verify \\"
log "       \"$SEED_REPO/\" \\"
log "       \"rdzupke@100.68.245.122:/Volumes/My Book for Mac/borg-backup-hecate/\""
log ""
log "  3. Verify the archive landed on Hyperion:"
log "     source ~/.borg-env"
log "     borg list \"rdzupke@100.68.245.122:/Volumes/My Book for Mac/borg-backup-hecate\""
log ""
log "  4. Once verified, delete the local seed repo:"
log "     rm -rf $SEED_REPO"
log ""
log "  5. Run borg-backup-hecate.sh for all future backups."
