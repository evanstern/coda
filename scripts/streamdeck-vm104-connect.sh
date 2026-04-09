#!/bin/bash
#
# streamdeck-vm104-connect.sh
#
# Stream Deck button script: Open Ghostty -> SSH to vm-104 -> auto-attach tmux
#
# RUNS ON YOUR LOCAL MAC — not on the VM.
#
# Setup:
#   1. Copy this script to your Mac (e.g. ~/scripts/streamdeck-vm104-connect.sh)
#   2. chmod +x ~/scripts/streamdeck-vm104-connect.sh
#   3. In Stream Deck app: add a "System: Open" action
#   4. Point it to this script
#
# What happens when you press the button:
#   - Ghostty opens a new window
#   - SSH connects to vm-104
#   - tmux auto-attaches (AUTO_ATTACH_TMUX=true on the VM)
#   - You're in. Run `coda switch` to pick a session.
#
# To skip the password prompt every time, set up SSH key auth:
#   ssh-keygen -t ed25519                        # if you don't have a key yet
#   ssh-copy-id coda@vm-104.local.infinity-node.win
#

HOST="vm-104.local.infinity-node.win"
USER="coda"

osascript - "$USER" "$HOST" <<'APPLESCRIPT'
on run argv
    set sshUser to item 1 of argv
    set sshHost to item 2 of argv
    set sshCmd to "ssh -t " & sshUser & "@" & sshHost

    tell application "Ghostty" to activate
    delay 1.0

    tell application "System Events"
        tell process "Ghostty"
            keystroke sshCmd
            delay 0.1
            key code 36
        end tell
    end tell
end run
APPLESCRIPT
