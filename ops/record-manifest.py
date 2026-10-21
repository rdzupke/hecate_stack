#!/usr/bin/env python3
"""
record-manifest.py — Captures active container versions and image digests
before running Borg backups. Writes per-service and central manifests.
"""

import argparse
import datetime
import json
import os
import subprocess
import sys

def get_container_details(container_id):
    """Query docker inspect for a container and its image digests."""
    try:
        inspect_out = subprocess.check_output(
            ["docker", "inspect", container_id],
            text=True,
            stderr=subprocess.DEVNULL
        )
        container_data = json.loads(inspect_out)[0]
    except Exception as e:
        print(f"Warning: Failed to inspect container {container_id}: {e}", file=sys.stderr)
        return None

    name = container_data.get("Name", "").lstrip("/")
    labels = container_data.get("Config", {}).get("Labels", {}) or {}
    service = labels.get("com.docker.compose.service", name)
    project = labels.get("com.docker.compose.project", "")
    image_tag = container_data.get("Config", {}).get("Image", "")
    image_id = container_data.get("Image", "")

    repo_digest = None
    if image_id:
        try:
            img_out = subprocess.check_output(
                ["docker", "image", "inspect", image_id],
                text=True,
                stderr=subprocess.DEVNULL
            )
            img_data = json.loads(img_out)[0]
            digests = img_data.get("RepoDigests", [])
            if digests:
                # Find matching digest for image_tag or default to first
                base_repo = image_tag.split(":")[0] if ":" in image_tag else image_tag
                matched = [d for d in digests if d.startswith(base_repo + "@")]
                repo_digest = matched[0] if matched else digests[0]
        except Exception:
            pass

    return {
        "service": service,
        "container_name": name,
        "image": image_tag,
        "image_id": image_id,
        "repo_digest": repo_digest or image_id or "unknown",
        "project": project
    }

def generate_service_markdown(stack_name, archive_name, timestamp_str, containers):
    lines = [
        f"# Backup Version Checkpoint — {stack_name}",
        f"- **Stack:** `{stack_name}`",
        f"- **Borg Archive:** `{archive_name}`",
        f"- **Timestamp:** {timestamp_str}",
        "",
        "| Service | Container | Image Tag | Image Digest (SHA256) |",
        "|---|---|---|---|"
    ]
    for c in containers:
        lines.append(f"| `{c['service']}` | `{c['container_name']}` | `{c['image']}` | `{c['repo_digest']}` |")
    lines.append("")
    return "\n".join(lines)

def generate_central_markdown(archive_name, timestamp_str, stacks_dict):
    lines = [
        "# Backup Container Manifest",
        f"- **Archive:** `{archive_name}`",
        f"- **Timestamp:** {timestamp_str}",
        f"- **Active Stacks Count:** {len(stacks_dict)}",
        "",
        "## Active Stacks",
        ""
    ]
    for stack_name in sorted(stacks_dict.keys()):
        stack_info = stacks_dict[stack_name]
        lines.append(f"### {stack_name}")
        lines.append("")
        lines.append("| Service | Container | Image Tag | Image Digest (SHA256) |")
        lines.append("|---|---|---|---|")
        for c in stack_info["containers"]:
            lines.append(f"| `{c['service']}` | `{c['container_name']}` | `{c['image']}` | `{c['repo_digest']}` |")
        lines.append("")
    return "\n".join(lines)

def main():
    parser = argparse.ArgumentParser(description="Record running container versions for backup manifest.")
    parser.add_argument("--stack-root", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "..")),
                        help="Root directory containing compose stack folders.")
    parser.add_argument("--archive-name", default=f"hecate-{datetime.datetime.now().strftime('%Y-%m-%dT%H:%M')}",
                        help="Name of the Borg backup archive.")
    parser.add_argument("--timestamp", default=datetime.datetime.now().astimezone().isoformat(),
                        help="ISO timestamp of the backup checkpoint.")
    args = parser.parse_args()

    stack_root = os.path.abspath(args.stack_root)
    archive_name = args.archive_name
    timestamp_str = args.timestamp

    # Query all running containers
    try:
        ps_out = subprocess.check_output(["docker", "ps", "-q"], text=True).strip().split()
    except Exception as e:
        print(f"Error checking running containers: {e}", file=sys.stderr)
        sys.exit(1)

    if not ps_out:
        print("No running containers found.")
        return

    # Map containers by stack
    stacks = {}
    for cid in ps_out:
        details = get_container_details(cid)
        if not details:
            continue
        
        project = details["project"]
        if not project:
            # Fallback: check container name or skip
            project = details["service"]

        stack_dir = os.path.join(stack_root, project)
        if project not in stacks:
            stacks[project] = {
                "path": stack_dir,
                "containers": []
            }
        stacks[project]["containers"].append({
            "service": details["service"],
            "container_name": details["container_name"],
            "image": details["image"],
            "image_id": details["image_id"],
            "repo_digest": details["repo_digest"]
        })

    # 1. Write per-service manifests
    for stack_name, stack_info in stacks.items():
        sdir = stack_info["path"]
        if os.path.isdir(sdir):
            svc_json_path = os.path.join(sdir, "backup-versions.json")
            svc_md_path = os.path.join(sdir, "BACKUP_VERSIONS.md")

            svc_payload = {
                "stack": stack_name,
                "backup_archive": archive_name,
                "timestamp": timestamp_str,
                "containers": stack_info["containers"]
            }

            try:
                with open(svc_json_path, "w", encoding="utf-8") as f:
                    json.dump(svc_payload, f, indent=2)
                with open(svc_md_path, "w", encoding="utf-8") as f:
                    f.write(generate_service_markdown(stack_name, archive_name, timestamp_str, stack_info["containers"]))
            except Exception as e:
                print(f"Warning: Failed to write service manifest for {stack_name}: {e}", file=sys.stderr)

    # 2. Write central manifests in ops/
    ops_dir = os.path.join(stack_root, "ops")
    os.makedirs(ops_dir, exist_ok=True)
    
    central_json_path = os.path.join(ops_dir, "backup-manifest.json")
    central_md_path = os.path.join(ops_dir, "backup-manifest.md")

    central_payload = {
        "backup_archive": archive_name,
        "timestamp": timestamp_str,
        "active_stacks_count": len(stacks),
        "stacks": stacks
    }

    try:
        with open(central_json_path, "w", encoding="utf-8") as f:
            json.dump(central_payload, f, indent=2)
        with open(central_md_path, "w", encoding="utf-8") as f:
            f.write(generate_central_markdown(archive_name, timestamp_str, stacks))
        print(f"Successfully recorded version checkpoints for {len(stacks)} stack(s) to central and per-service manifests.")
    except Exception as e:
        print(f"Error writing central backup manifest: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
