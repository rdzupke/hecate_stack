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