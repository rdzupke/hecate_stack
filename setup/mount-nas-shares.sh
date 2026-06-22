#!/bin/bash
#
# mount-nas-shares.sh
#
# Automatically mounts SMB shares from a Synology DS220+ NAS.
# Designed to be run at login via a LaunchAgent, and also safely
# re-run every 60 seconds to recover from network interruptions.
#
# SETUP NOTES:
#
# 1. KEYCHAIN CREDENTIAL STORAGE
#    The script retrieves the NAS password from the macOS Keychain rather
#    than hardcoding it. To store the password, first unlock the keychain
#    if needed, then add the credential:
#
#      security unlock-keychain ~/Library/Keychains/login.keychain-db
#      security add-internet-password -U -a "rdzupke" -s "ds220plus.local" -r "smb " -w "yourpassword"
#
#    The -U flag updates the entry if it already exists.
#    The -r "smb " flag (note trailing space) sets the protocol to SMB.
#
# 2. KEYCHAIN ACCESS PERMISSION
#    The first time this script runs and calls `security find-internet-password`,
#    macOS will pop up a dialog asking if the script should be allowed to access
#    the keychain entry. You must click "Always Allow" to permit non-interactive
#    access for future runs (including via LaunchAgent).
#
# 3. LAUNCHAGENT
#    Install the companion plist (from the hecate_stack repo) at:
#       ~/Library/LaunchAgents/com.local.mount-nas.plist
#    Then load it with:
#      launchctl load ~/Library/LaunchAgents/com.local.mount-nas.plist
#
# 4. MOUNT POINT DIRECTORIES
#    macOS manages mount point directories in /Volumes automatically when
#    using osascript to mount. Do NOT pre-create stub directories for
#     /Volumes/home or /Volumes/Plex — macOS will append a -1 suffix to
#    avoid conflicts, which breaks the is_mounted detection logic.
#
# 5. DEBUGGING
#    Run the script interactively from a terminal to see timestamped debug
#    output. When run via LaunchAgent (non-interactive), all output is
#    suppressed. LaunchAgent stdout/stderr are logged to:
#       /tmp/mount-nas.out
#       /tmp/mount-nas.err
#

# Detect if running interactively (from terminal) or via launchd
if [ -t 1 ]; then
    DEBUG=true
else
    DEBUG=false
fi

debug() {
    if [ "$DEBUG" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
}

# Check if a named share is actively mounted from the NAS.
# Matches by share name in the mount table rather than by /Volumes path,
# so it works regardless of what suffix macOS assigns to the mount point.
is_mounted() {
    mount | grep -qE "ds220plus\.local/$1 "
}

debug "Starting NAS share mount check"

# Check if the NAS SMB port is reachable (timeout 2 seconds)
if ! nc -z -G 2 ds220plus.local 445 >/dev/null 2>&1; then
    debug "NAS ds220plus.local is not reachable on port 445. Skipping mount check."
    exit 0
fi

# Retrieve NAS password from Keychain.
# See SETUP NOTES above for how to store this credential.
PASSWORD=$(security find-internet-password -w -a "rdzupke" -s "ds220plus.local")

if [ -z "$PASSWORD" ]; then
    debug "ERROR: Could not retrieve password from Keychain"
    debug "Run: security add-internet-password -U -a \"rdzupke\" -s \"ds220plus.local\" -r \"smb \" -w \"yourpassword\""
    exit 0
fi

# Mount home share
if ! is_mounted "home"; then
    debug "Mounting home share..."
    osascript -e "mount volume \"smb://rdzupke:$PASSWORD@ds220plus.local/home\""
    if [ $? -eq 0 ]; then
        debug "Successfully mounted home share"
    else
        debug "Failed to mount home share"
    fi
else
    debug "home share is already mounted"
fi

# Mount Plex share
if ! is_mounted "Plex"; then
    debug "Mounting Plex share..."
    osascript -e "mount volume \"smb://rdzupke:$PASSWORD@ds220plus.local/Plex\""
    if [ $? -eq 0 ]; then
        debug "Successfully mounted Plex share"
    else
        debug "Failed to mount Plex share"
    fi
else
    debug "Plex share is already mounted"
fi

debug "Mount check complete"
