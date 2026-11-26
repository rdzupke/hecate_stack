# Plex integration

Plex runs natively on the same host and reads `../media` with the legacy
[tubearchivist-plex](https://github.com/tubearchivist/tubearchivist-plex) scanner
and agent (installed version dated 2025-06-09). These files live in the Plex data
folder, outside this repo:

    ~/Library/Application Support/Plex Media Server

## Connection settings

Plex must use the local port published in `../docker-compose.yml`. The public
hostname does not work: Cloudflare rejects the plugin's requests.

| Component | File (under the Plex data folder) | Setting |
|---|---|---|
| Scanner | `Scanners/Series/ta_config.json` | `"ta_url": "http://localhost:8010"` |
| Agent | `Plug-in Support/Preferences/com.plexapp.agents.tubearchivist_agent.xml` | `<tubearchivist_url>http://localhost:8010</tubearchivist_url>` |

Both also need a TubeArchivist API token. Do not commit it.

## Local patch: skip missing images

`agent-skip-missing-images.patch` changes the agent so it only downloads an image
when TubeArchivist returns a URL for it. Without the patch, a channel with no
banner or background art raises `nonnumeric port: '8010None'`, and the metadata
update for that channel stops.

Reinstalling or updating the plugin removes the patch.

### Reapply

Run from the root of this repo:

```sh
patch_file="$PWD/tubearchivist/plex/agent-skip-missing-images.patch"
bundle="$HOME/Library/Application Support/Plex Media Server/Plug-ins/TubeArchivist-Agent.bundle"

patch -d "$bundle" -p1 --dry-run < "$patch_file" &&
  patch -d "$bundle" -p1 -b < "$patch_file"
```

Then restart Plex and run **Refresh Metadata** on the affected show.

If the dry run fails, the plugin has changed upstream. Check whether it still
needs the fix before editing anything. If `patch` reports that the change is
already applied, answer no.

### Checksums of `Contents/Code/__init__.py`

| Version | SHA-256 |
|---|---|
| Original | `64987edac09a0c437d2afc0708f3cb10b09aa40a8a2c94ef84bc3cf1c1fd080e` |
| Patched | `76b110467633000860b69c44f44f361c2612235a2e32787d120fd63ef2f1ec8a` |
