#!/bin/bash
#
# edgeOS Persistent Claude — Appdata Backup pre-run hook
# By: Edge
#
# Updated: Oct 1, 2026
#
# Appdata Backup stops the Coder workspace containers every night, which kills
# tmux and the Claude Code process inside it. This runs first and asks each
# workspace's running Claude to finish its session, so the conversation's durable
# knowledge — the session record, STATUS.md, NEXT.md — is on disk before the
# container goes away. Recovery afterwards is not this script's job: the Coder
# workspace's own run_on_start script recreates tmux and Claude, which also covers
# a reboot, a Docker restart, and an unexpected container restart.
#
# What it does NOT do, deliberately:
#   - stop, start, or restart any container. Appdata Backup owns that lifecycle.
#   - block the backup. It always exits 0 and reports through Unraid notifications.
#   - use SSH. docker exec reaches a workspace whether or not sshd is running in
#     it and whether or not it published a LAN SSH port.
#   - name any workspace. Containers are discovered by the labels the edgeOS
#     Coder template puts on every one of them.
#
# Exit codes from edgeos-claude-finish, and what each means here:
#
#   0  finished and confirmed by a fresh completion marker   proceed
#   3  nothing to do — no repo opted in, or no session       proceed, quietly
#   4  refused safely — unsent input, a menu, or busy        proceed, notify
#   5  injected but not confirmed before the timeout         proceed, notify loudly
#   *  unexpected, including a docker exec that timed out    proceed, notify loudly
#
# A refusal is a feature. If somebody is mid-sentence in that session, or Claude
# is waiting on a permission prompt, finish declines rather than typing over it.
# Losing one nightly session record costs a record; typing into someone's session
# costs their words.

set -u

###################################################################################
# Tunables
EVENT="edgeOS Persistent Claude"
NOTIFY="/usr/local/emhttp/webGui/scripts/notify"

# Inside the workspace. The edgeOS Coder template standardises on the coder user
# and symlinks these commands into ~/bin from the edgeOS revision it pins.
FINISH="/home/coder/bin/edgeos-claude-finish"
WORKSPACE_HOME="/home/coder"

# How long finish waits for Claude to write its completion marker, and the outer
# bound on the docker exec that carries it. The outer bound exists so a wedged
# exec cannot hold the backup open past its own timeout.
FINISH_TIMEOUT=900
EXEC_TIMEOUT=1020

# The label every edgeOS Coder workspace container carries.
LABEL="coder.workspace_name"

###################################################################################
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# notify <icon> <subject> <description>
notify () {
  if [[ ! -x "$NOTIFY" ]]; then
    log "cannot notify: $NOTIFY is missing"
    return 0
  fi
  "$NOTIFY" -i "$1" -e "$EVENT" -s "$2" -d "$3" >/dev/null 2>&1 || true
}

# Worst-wins, in increasing order of "somebody should look at this".
rank () {
  case "$1" in
    0) echo 0 ;;
    3) echo 1 ;;
    4) echo 2 ;;
    5) echo 3 ;;
    *) echo 4 ;;
  esac
}

worst=0
record_rc () {
  if [[ "$(rank "$1")" -gt "$(rank "$worst")" ]]; then
    worst="$1"
  fi
}

finish_one () {
  local container="$1" workspace="$2" rc

  log "=== $container  (workspace ${workspace:-unknown})"

  # A workspace built from an older template version has no edgeos-claude. That
  # is not a failure; there is simply nothing to finish there.
  if ! docker exec "$container" test -x "$FINISH" >/dev/null 2>&1; then
    log "    $FINISH is absent — workspace predates persistent Claude, skipping"
    return 0
  fi

  # -u coder because the tmux server and Claude belong to that user, and HOME
  # explicitly because docker exec does not reliably set it and edgeos-claude
  # resolves the development root and the Claude binary from it.
  timeout "$EXEC_TIMEOUT" \
    docker exec -u coder -e HOME="$WORKSPACE_HOME" "$container" \
      "$FINISH" --all --timeout "$FINISH_TIMEOUT" 2>&1 | sed 's/^/    /'
  rc="${PIPESTATUS[0]}"

  case "$rc" in
    0) log "    exit 0 — finished and confirmed" ;;
    3) log "    exit 3 — nothing to finish" ;;
    4) log "    exit 4 — refused safely, session left untouched" ;;
    5) log "    exit 5 — injected but not confirmed within ${FINISH_TIMEOUT}s" ;;
    124) log "    exit 124 — docker exec exceeded ${EXEC_TIMEOUT}s and was killed" ;;
    *) log "    exit $rc — unexpected" ;;
  esac

  record_rc "$rc"
  return 0
}

###################################################################################
log "pre-backup hook starting"

if ! command -v docker >/dev/null 2>&1; then
  log "docker is not on PATH; no workspace could be finalised"
  notify alert "Pre-backup hook could not run" \
    "docker was not found on PATH, so no Claude session was finalised. The backup proceeded."
  exit 0
fi

# Running containers only — docker ps without -a — so a stopped workspace is
# silently skipped rather than treated as a problem.
containers="$(docker ps --filter "label=$LABEL" --format '{{.Names}}' 2>/dev/null)"

if [[ -z "$containers" ]]; then
  log "no running Coder workspace containers; nothing to do"
  exit 0
fi

count=0
while read -r container; do
  [[ -n "$container" ]] || continue
  count=$((count + 1))
  workspace="$(docker inspect -f "{{index .Config.Labels \"$LABEL\"}}" "$container" 2>/dev/null)"
  finish_one "$container" "$workspace"
done <<< "$containers"

log "examined $count running workspace container(s); worst exit $worst"

case "$worst" in
  0)
    log "all sessions finished and confirmed"
    ;;
  3)
    log "nothing needed finishing"
    ;;
  4)
    notify warning "Claude finish refused" \
      "A workspace declined to finish: unsent input in the prompt, an open permission or setup screen, or Claude still working. Nothing was typed into the session and the backup proceeded. That session's notes were not written."
    ;;
  5)
    notify alert "Claude finish NOT confirmed" \
      "/finish was sent to a workspace but no completion marker appeared within ${FINISH_TIMEOUT}s. That session's durable notes may be missing. Claude was left running and the backup proceeded."
    ;;
  *)
    notify alert "Claude finish hit an unexpected error (exit $worst)" \
      "The pre-backup hook could not finish a workspace cleanly. See the Appdata Backup log for the per-container output. The backup proceeded."
    ;;
esac

log "pre-backup hook done"

# Always zero. A backup must never be skipped because a Claude session could not
# be tidied up first.
exit 0
