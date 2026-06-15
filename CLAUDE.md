# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a home server setup repository that manages multiple services using Docker Compose. The repository contains configuration files for various applications and tools, primarily focused on building a personal media server ecosystem.

## High-Level Architecture

The repository is organized around a collection of Docker-based services that are orchestrated using docker-compose files:

- **nginxpm**: Nginx Proxy Manager for reverse proxy and SSL termination
- **paperless**: Document management system for scanning and organizing documents
- **memos**: A note-taking application
- **romm**: Game library management system
- **grocy**: Grocery management and household inventory
- **linkwarden**: Bookmark manager
- **audiobookshelf**: Audiobook management system
- **mealie**: Recipe management system
- **vaultwarden**: Password manager (Bitwarden server)
- **tubearchivist**: YouTube archiving and management
- **lubelogger**: Vehicle maintenance tracking
- **uptime-kuma**: Monitoring system
- **yamtrack**: Possibly a tracking system
- **airtrail**: Possibly a tracking system
- **termix**: Terminal-based tools
- **dev/**: Development tools and applications

## Key Directories and Services

- `nginxpm/` - Nginx Proxy Manager for reverse proxy configuration
- `paperless/` - Document management with Redis broker
- `memos/` - Note-taking application
- `romm/` - Game library management with MariaDB backend
- `grocy/` - Grocery inventory management
- `linkwarden/` - Bookmark manager
- `audiobookshelf/` - Audiobook management
- `mealie/` - Recipe management
- `vaultwarden/` - Password manager
- `tubearchivist/` - YouTube archiving
- `lubelogger/` - Vehicle maintenance tracking
- `uptime-kuma/` - Monitoring
- `dev/` - Development tools including various projects like dawarich, openclaw, etc.

## Common Development Tasks

- **Starting services**: `docker compose up -d` in individual service directories
- **Stopping services**: `docker compose down` in individual service directories
- **Viewing logs**: `docker compose logs` in individual service directories
- **Updating services**: `docker compose pull` followed by `docker compose up -d` in individual service directories

## Important Notes

- Most services use external networks (nginx-net) for communication
- Many services have volume mounts for persistent data storage
- Configuration files are typically in `.env` format for environment variables
- The repository is structured to be a centralized home server configuration
- The main entry point for local access is Nginx Proxy Manager, while Cloudflared handles external access

## Service Orchestration

All services are orchestrated through Docker Compose, with a consistent pattern:
- Services communicate through Docker networks
- External network `nginx-net` is used for routing traffic to services
- Most services have dedicated internal networks for communication
- Data persistence is handled through Docker volumes
- Environment variables are used for configuration management

## Secrets Management

When working with this repository, it's crucial to understand how to properly manage secrets and sensitive data:

1. **Never commit secrets**: Do not commit passwords, API keys, or other sensitive information to the repository
2. **Use .env files**: Most services use `.env` files for configuration, which should be ignored by git
3. **Environment variables**: Secrets are typically stored in environment variables or `.env` files that are excluded from version control
4. **Docker secrets**: For services that support it, use Docker's native secrets management
5. **Encryption**: For highly sensitive data, consider using encryption tools like Ansible Vault, git-crypt, or similar
6. **Service-specific approaches**:
   - `vaultwarden` uses environment variables for configuration
   - `paperless` uses environment variables for database credentials and other settings
   - `romm` uses environment variables for database and authentication settings
   - `nginxpm` uses environment variables for configuration
7. **Best practices**:
   - Use strong, unique passwords for each service
   - Rotate secrets regularly
   - Use different credentials for different services
   - Keep sensitive data in a secure location separate from the repository
   - Use a secrets management tool or service (like 1Password, HashiCorp Vault, etc.) for production deployments

## Development Environment Setup

To work with this repository:
1. Ensure Docker is installed and running
2. Clone the repository
3. Navigate to individual service directories
4. Review the docker-compose.yml and .env files for configuration
5. Run `docker compose up -d` to start services
6. Access services through the configured entry points

## Testing and Validation

- Each service should be tested individually
- Verify network connectivity between services using Docker networks
- Check that all required volumes are properly mounted
- Ensure that environment variables are correctly set in .env files
- Validate that services start correctly and respond to requests