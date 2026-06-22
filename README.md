# README.md

## Hecate Stack - Home Server Setup

This repository contains the configuration files and setup for my personal home server ecosystem. It orchestrates multiple services using Docker Compose to create a comprehensive media server and productivity environment.

## Overview

The Hecate Stack is a collection of Docker-based services that are orchestrated using docker-compose files. It provides a centralized home server configuration with services for document management, media organization, productivity tools, and more.

## Services Included

- **nginxpm**: Nginx Proxy Manager for reverse proxy and SSL termination
- **cloudflared**: External access via Cloudflare Tunnel
- **paperless**: Document management system for scanning and organizing documents
- **memos**: A note-taking application
- **romm**: Game library management system
- **grocy**: Grocery management and household inventory
- **linkwarden**: Bookmark manager
- **audiobookshelf**: Audiobook management system
- **mealie**: Recipe management system
- **open-webui**: Web UI for AI/LLM interactions (Ollama)
- **vaultwarden**: Password manager (Bitwarden server)
- **tubearchivist**: YouTube archiving and management
- **immich**: Photo and media management
- **lubelogger**: Vehicle maintenance tracking
- **uptime-kuma**: Monitoring system
- **yamtrack**: Tracking system
- **airtrail**: Tracking system

## NAS Mount Setup (macOS)

This repository uses services that rely on `/Volumes/home` and `/Volumes/Plex` being
mounted from a Synology NAS. These are mounted automatically via a macOS LaunchAgent
plus shell script pair located in the `setup/` directory.

### Prerequisites

- macOS with `nc` (netcat) available
- A Synology NAS accessible on your network (default: `ds220plus.local`)

### Installation

**1. Store NAS credentials in the macOS Keychain**

Unlock your keychain if needed, then run:

```bash
security add-internet-password -U -a "rdzupke" -s "ds220plus.local" -r "smb " -w "yourpassword"
```

- `-a` = keychain account (NAS username)
- `-s` = server name (NAS hostname)
- `-r "smb "` = resource type (must include trailing space for SMB)
- `-w` = password (omit to be prompted)

**2. Install the LaunchAgent plist**

Copy the plist to your LaunchAgents directory and update the script path:

```bash
cp setup/com.local.mount-nas.plist ~/Library/LaunchAgents/com.local.mount-nas.plist
```

Edit `~/Library/LaunchAgents/com.local.mount-nas.plist` and replace
`REPLACE_WITH_PATH_TO` with the absolute path to this repository (e.g.,
`/Users/rdzupke/git/rdzupke/hecate_stack`).

**3. Load the LaunchAgent**

```bash
launchctl load ~/Library/LaunchAgents/com.local.mount-nas.plist
```

This will:
- Mount NAS shares immediately (`RunAtLoad: true`)
- Re-check and re-mount every 60 seconds to recover from network interruptions
- Log output to `/tmp/mount-nas.out` and `/tmp/mount-nas.err`

**4. Allow Keychain access**

The first time the script runs, macOS will prompt you to allow it access to the
Keychain entry. Click **"Always Allow"** so future runs (including via LaunchAgent)
work without interaction.

### Configuration

Edit the following files in `setup/` to match your setup:

- **`com.local.mount-nas.plist`** — update the script path placeholder
- **`mount-nas-shares.sh`** — update `ds220plus.local`, the username (`rdzupke`),
  and keychain account name to match your NAS

### Important Notes

- **Do NOT pre-create** mount point directories for `/Volumes/home` or `/Volumes/Plex`
  — macOS manages these automatically. Pre-creating them causes macOS to append a
  `-1` suffix, which breaks the mount detection logic.
- When run via LaunchAgent (non-interactive), all output is suppressed. Use the
  log files at `/tmp/mount-nas.out` and `/tmp/mount-nas.err` for debugging.

## Architecture

The repository follows a consistent pattern where:
- All services use Docker Compose for orchestration
- Services communicate through Docker networks
- External network `nginx-net` is used for routing traffic to services
- Most services have dedicated internal networks for communication
- Data persistence is handled through Docker volumes
- Environment variables are used for configuration management

## Entry Points

- **Local Access**: Nginx Proxy Manager (NPM) serves as the local entry point for accessing services internally
- **External Access**: Cloudflared is configured as the main external entry point for remote access to services

## Getting Started

1. Ensure Docker is installed and running on your system
2. Clone this repository
3. Navigate to individual service directories
4. Review the docker-compose.yml and .env files for configuration
5. Run `docker compose up -d` to start services
6. Access services through the configured entry points

## Common Operations

- **Starting services**: `docker compose up -d` in individual service directories
- **Stopping services**: `docker compose down` in individual service directories
- **Viewing logs**: `docker compose logs` in individual service directories
- **Updating services**: `docker compose pull` followed by `docker compose up -d` in individual service directories

## Security

- All services use `.env` files for configuration
- Sensitive information is stored in environment variables or `.env` files that are excluded from version control
- The repository is structured to be a centralized home server configuration
- Nginx Proxy Manager handles internal routing and SSL termination
- Cloudflared provides external access with additional security layers

## Contributing

This repository is primarily for personal use, but contributions are welcome. Please follow the existing patterns and conventions.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- Thanks to all the open source projects that make this setup possible
- Special thanks to the Docker community and all service maintainers

## Note

This repository is a work in progress and may change as new services are added or existing ones are updated.