# Security TODOs

## Critical / High Priority
- [ ] **[SECRET EXPOSURE]** Remove hardcoded `TOKEN` and `KEY` from `beszel/docker-compose.yml` and move them to an `.env` file. (Rotate credentials immediately after)
- [ ] **[RISK]** `open-webui` is using `:main` tag. Pin to a specific release version (e.g., `:0.3.x`).
- [ ] **[RISK]** `uptime-kuma` uses `/var/run/docker.sock:ro`. Investigate alternative, less-privileged monitoring methods (e.g., HTTP monitoring).

## Hardening & Best Practices
- [ ] **[TAGGING]** Audit and pin all services using `:latest` or unstable tags to specific version numbers.
- [ ] **[RESOURCE LIMITS]** Implement `deploy.resources.limits` for all services to prevent resource exhaustion.
- [ ] **[PRIVILEGE]** Enforce non-root user execution (`user: ...`) for all containers, or migrate to rootless image variants where available (e.g., `homebox-rootless`).
- [ ] **[CLEANUP]** Audit `mealie/docker-compose.yml` and remove/properly manage the hardcoded dummy API key.
