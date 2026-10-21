# Hecate Stack — Backup & Disaster Recovery Guide

This directory contains backup orchestration scripts and recovery documentation for the entire `hecate_stack` home server ecosystem.

Because this directory is located inside `/Users/rdzupke/git/rdzupke/hecate_stack/ops`, this documentation is automatically included in every Borg backup archive created by `borg-backup.sh`.

---

## 1. Backup Architecture & Configuration

- **Source Directory:** `/Users/rdzupke/git/rdzupke/hecate_stack` (all compose configurations, `.env` files, local state, and operational tooling)
- **Target Remote Repository:** `rdzupke@100.68.245.122:/Volumes/My Book for Mac/borg-backup-hecate` (Hyperion)
- **Encryption:** `repokey-blake2` (authenticated encryption)
- **SSH Key:** `~/.ssh/borg_backup_key`
- **Passphrase Storage:** `~/.borg-passphrase`
- **Archive Naming:** `hecate-YYYY-MM-DDTHH:MM`
- **Retention Policy:**
  - Daily: 7
  - Weekly: 4
  - Monthly: 6

---

## 2. Prerequisites & Environment Setup

Before running any Borg commands on a recovery machine or troubleshooting host, set up the required environment:

### A. Install BorgBackup

- **macOS (Homebrew):**
  ```bash
  brew install borgbackup
  # Optional (for FUSE mounting archives):
  brew install macfuse
  ```

- **Debian / Ubuntu / Linux:**
  ```bash
  sudo apt update && sudo apt install -y borgbackup
  # Optional (for FUSE mounting):
  sudo apt install -y python3-llfuse fuse
  ```

### B. Configure Environment Variables

Set the environment variables needed to authenticate against the remote repository:

```bash
export REMOTE_REPO="rdzupke@100.68.245.122:/Volumes/My Book for Mac/borg-backup-hecate"
export BORG_PASSPHRASE="$(cat ~/.borg-passphrase)"   # Or enter interactively if file is absent
export BORG_RSH="ssh -i ~/.ssh/borg_backup_key"
export BORG_REMOTE_PATH="/opt/homebrew/bin/borg"     # Path to borg binary on Hyperion
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
```

> **Note:** If you are accessing the external drive (`My Book for Mac`) plugged directly into your local machine instead of over SSH, set `REMOTE_REPO` to the local path:
> ```bash
> export REMOTE_REPO="/Volumes/My Book for Mac/borg-backup-hecate"
> unset BORG_RSH
> unset BORG_REMOTE_PATH
> ```

---

## 3. Browsing and Inspecting Backups

### List All Archives in the Repository

```bash
borg list "$REMOTE_REPO"
```

*Example output:*
```text
hecate-2026-10-01T03:00  Thu, 2026-10-01 03:00:12 [a1b2c3d4e5f6...]
hecate-2026-10-02T03:00  Fri, 2026-10-02 03:00:15 [b2c3d4e5f6a1...]
hecate-2026-10-03T03:00  Sat, 2026-10-03 03:00:18 [c3d4e5f6a1b2...]
```

### View Repository Details & Statistics

```bash
borg info "$REMOTE_REPO"
```

### List Files Inside a Specific Archive

```bash
# List all files
borg list "$REMOTE_REPO::hecate-2026-10-03T03:00"

# Filter for a specific service (e.g., vaultwarden or paperless)
borg list "$REMOTE_REPO::hecate-2026-10-03T03:00" | grep vaultwarden
```

### Checking Container Versions at Backup Time

Every Borg backup automatically tags and records the exact container versions and immutable image digests (SHA256) running at backup time:

1. **Central Manifests (`ops/`):**
   - `ops/backup-manifest.md` (human-readable table of all active stacks)
   - `ops/backup-manifest.json` (JSON manifest for programmatic use)

2. **Per-Service Manifests (`<service_dir>/`):**
   - `<service_dir>/BACKUP_VERSIONS.md`
   - `<service_dir>/backup-versions.json`

To check which image versions were running at the time of an archive without restoring everything:
```bash
# Extract only the manifest from a backup snapshot
borg extract "$REMOTE_REPO::hecate-2026-10-03T03:00" Users/rdzupke/git/rdzupke/hecate_stack/ops/backup-manifest.md
cat Users/rdzupke/git/rdzupke/hecate_stack/ops/backup-manifest.md
```

---

## 4. Restoration Methods

> **Important:** Borg extracts files relative to the current working directory.
> Always change into your target destination directory (or a temporary staging directory) before running `borg extract`. Borg will recreate the directory hierarchy (e.g. `Users/rdzupke/git/rdzupke/hecate_stack/...`) under the current directory.

### Method 1: Mount Archive as a Filesystem (Recommended for Granular Restores)

FUSE mounting allows you to browse archives as standard read-only folders and selectively copy files using `cp` or Finder.

```bash
# 1. Create a mount point
mkdir -p /tmp/borg-restore

# 2. Mount a specific archive (or mount the whole repo by omitting ::ARCHIVE)
borg mount "$REMOTE_REPO::hecate-2026-10-03T03:00" /tmp/borg-restore

# 3. Browse and copy required files/folders
cd /tmp/borg-restore
ls -la Users/rdzupke/git/rdzupke/hecate_stack/

# Example: copy a single stack back into place
cp -a Users/rdzupke/git/rdzupke/hecate_stack/vaultwarden /Users/rdzupke/git/rdzupke/hecate_stack/

# 4. Unmount when finished
cd ~
borg umount /tmp/borg-restore
```

---

### Method 2: Restore a Single Service / Subdirectory

To restore only one specific service stack (e.g., `vaultwarden`) directly using `borg extract`:

```bash
# 1. Choose a target staging directory
mkdir -p /tmp/restore-test
cd /tmp/restore-test

# 2. Extract only the desired path from the archive
borg extract --list --progress \
  "$REMOTE_REPO::hecate-2026-10-03T03:00" \
  Users/rdzupke/git/rdzupke/hecate_stack/vaultwarden

# 3. Stop running container if replacing live service
cd /Users/rdzupke/git/rdzupke/hecate_stack/vaultwarden
docker compose down

# 4. Copy restored data over
cp -a /tmp/restore-test/Users/rdzupke/git/rdzupke/hecate_stack/vaultwarden /Users/rdzupke/git/rdzupke/hecate_stack/

# 5. Restart service
cd /Users/rdzupke/git/rdzupke/hecate_stack/vaultwarden
docker compose up -d
```

---

### Method 3: Full Disaster Recovery (Complete Stack Restore)

To restore the entire `hecate_stack` to a new host or completely rebuild the existing machine:

```bash
# 1. Ensure Docker Desktop is installed and running
docker info

# 2. Prepare the destination parent directory
mkdir -p /Users/rdzupke/git/rdzupke
cd /Users/rdzupke/git/rdzupke

# Note: Extracting from root (/) or staging directory:
# Since Borg archives paths without leading slash (e.g., Users/rdzupke/...),
# extracting from / will place files directly into /Users/rdzupke/...
cd /
borg extract --progress "$REMOTE_REPO::hecate-2026-10-03T03:00"

# 3. Verify directory structure
cd /Users/rdzupke/git/rdzupke/hecate_stack
ls -la
```

---

## 5. Post-Restore Verification and Startup

After restoring files:

1. **Verify NAS mounts:**
   - If services rely on Synology shares (`/Volumes/home`, `/Volumes/Plex`), ensure they are mounted via `setup/mount-nas-shares.sh` or LaunchAgent.

2. **Verify Docker network:**
   - Ensure the shared external network exists:
     ```bash
     docker network create nginx-net || true
     ```

3. **Start Core Infrastructure First:**
   - **Nginx Proxy Manager:**
     ```bash
     cd /Users/rdzupke/git/rdzupke/hecate_stack/nginxpm && docker compose up -d
     ```
   - **Cloudflared Tunnel:**
     ```bash
     cd /Users/rdzupke/git/rdzupke/hecate_stack/cloudflared && docker compose up -d
     ```

4. **Start Application Stacks:**
   - Stacks with custom `prod.sh` scripts:
     ```bash
     cd /Users/rdzupke/git/rdzupke/hecate_stack/<service> && ./prod.sh
     ```
   - Standard compose stacks:
     ```bash
     cd /Users/rdzupke/git/rdzupke/hecate_stack/<service> && docker compose up -d
     ```

5. **Verify container health and logs:**
   ```bash
   docker ps
   docker compose logs -f
   ```

---

## 6. Emergency Recovery & Key Backup

### Key Export (Safeguard in Password Manager / Offline Drive)

If the Borg repository key is lost or corrupt, the encrypted archives **cannot** be decrypted.

```bash
# Export the repository encryption key
borg key export "$REMOTE_REPO" ~/borg-key-hecate.txt
```

> **Caution:** Keep `borg-key-hecate.txt` and the passphrase stored securely outside the server (e.g. 1Password/Bitwarden or secure cold storage).

### Key Import (Restoring on a brand new system with exported key)

```bash
borg key import "$REMOTE_REPO" ~/borg-key-hecate.txt
```

---

## 7. Quick Reference Cheat Sheet

| Action | Command |
|---|---|
| **List archives** | `borg list "$REMOTE_REPO"` |
| **List archive files** | `borg list "$REMOTE_REPO::$ARCHIVE"` |
| **Inspect archive** | `borg info "$REMOTE_REPO::$ARCHIVE"` |
| **Mount archive (FUSE)** | `borg mount "$REMOTE_REPO::$ARCHIVE" /tmp/mountpoint` |
| **Unmount** | `borg umount /tmp/mountpoint` |
| **Dry-run extract** | `borg extract --dry-run --list "$REMOTE_REPO::$ARCHIVE"` |
| **Extract single path** | `borg extract "$REMOTE_REPO::$ARCHIVE" path/to/extract` |
| **Extract all** | `borg extract --progress "$REMOTE_REPO::$ARCHIVE"` |
| **Check repository integrity** | `borg check --repository-only "$REMOTE_REPO"` |
| **Check archive integrity** | `borg check --archives-only "$REMOTE_REPO"` |
