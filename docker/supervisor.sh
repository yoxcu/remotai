#!/usr/bin/env bash
#
# supervisor.sh — PID 1's only child (tini reaps, this supervises).
#
# Runs two things and keeps them running:
#   1. sshd
#   2. if AGENT_CLAUDE=1, a tmux session `rc` holding a restart loop around
#      `claude remote-control`
#
# Codex needs no process here at all: the desktop app opens its own SSH
# connection and spawns `codex app-server` through the login shell.

set -uo pipefail

DEV_USER="${DEV_USER:-dev}"
DEV_HOME="${DEV_HOME:-/home/dev}"
PROJECTS="${DEV_HOME}/projects"
HOST_KEY_DIR="${DEV_HOME}/.ssh/host_keys"
RC_LOG="${DEV_HOME}/rc.log"
# `portal setup` drops this file while it walks a user through the one-time
# interactive logins, so the supervised loop does not race it for the same
# directory (and does not swallow the "Enable Remote Control?" prompt in a
# detached pane). Removed again at the end of setup.
RC_PAUSE="${DEV_HOME}/.rc-paused"
RC_SESSION=rc
RC_RESTART_DELAY="${RC_RESTART_DELAY:-5}"      # between `claude remote-control` attempts
RC_AUTH_POLL="${RC_AUTH_POLL:-30}"             # between re-checks while not logged in
RC_SUPERVISE_POLL="${RC_SUPERVISE_POLL:-10}"   # between "is the tmux session alive"
RC_LOG_MAX=$(( 8 * 1024 * 1024 ))

AGENT_NAME="${AGENT_NAME:-${DEV_USER}}"
AGENT_HOST="${AGENT_HOST:-$(hostname)}"
AGENT_CLAUDE="${AGENT_CLAUDE:-0}"

log() { printf '[%s] supervisor: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
rc_log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"${RC_LOG}"; }

as_dev() { su -l "${DEV_USER}" -c "$1"; }

# ---------------------------------------------------------------------------
# Environment hygiene.
# ---------------------------------------------------------------------------
# Remote Control only works with a claude.ai account login. Any of these being
# set — even to an empty string, even inherited from the daemon — sends Claude
# Code down an API-key or self-hosted code path instead, or trips the
# nonessential-traffic guard. We never set them; this strips anything that
# arrived from outside.
scrub_env() {
    local var found=0
    for var in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
               ANTHROPIC_BASE_URL DISABLE_TELEMETRY DO_NOT_TRACK \
               CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC DISABLE_GROWTHBOOK; do
        if [ -n "${!var+x}" ]; then
            log "WARNING: ${var} was set in this container's environment; unsetting it (it breaks Remote Control)"
            unset "${var}"
            found=1
        fi
    done
    return "${found}"
}

# ---------------------------------------------------------------------------
# First-boot setup.
# ---------------------------------------------------------------------------
seed_home() {
    # A fresh named volume normally arrives pre-populated from the image, but a
    # volume created by hand is empty. Either way, make sure the shape is right.
    if [ ! -e "${DEV_HOME}/.bashrc" ]; then
        log "seeding empty ${DEV_HOME} from /etc/skel"
        cp -a /etc/skel/. "${DEV_HOME}/" 2>/dev/null || true
    fi
    mkdir -p "${DEV_HOME}/.ssh" "${HOST_KEY_DIR}" \
             "${DEV_HOME}/.local/bin" "${DEV_HOME}/.npm-global" "${PROJECTS}"
    chown "${DEV_USER}:${DEV_USER}" \
        "${DEV_HOME}" "${DEV_HOME}/.ssh" "${DEV_HOME}/.local" \
        "${DEV_HOME}/.local/bin" "${DEV_HOME}/.npm-global" 2>/dev/null || true
    chmod 700 "${DEV_HOME}/.ssh"
    # Not recursive and not the bind mount: /home/dev/projects belongs to the
    # host and is already owned correctly by `portal add`.
    touch "${RC_LOG}" && chown "${DEV_USER}:${DEV_USER}" "${RC_LOG}"
    # A container that died mid-setup must not come back paused forever.
    rm -f "${RC_PAUSE}"
}

ensure_host_keys() {
    local type file
    for type in ed25519 rsa; do
        file="${HOST_KEY_DIR}/ssh_host_${type}_key"
        if [ ! -f "${file}" ]; then
            log "generating ${type} host key (first boot)"
            ssh-keygen -q -t "${type}" -N '' -f "${file}" -C "work-${AGENT_NAME}"
        fi
    done
    # Owned by root so the container's own user cannot swap them out; sshd
    # refuses to start on group/world-readable private keys.
    chown root:root "${HOST_KEY_DIR}"/ssh_host_* 2>/dev/null || true
    chmod 600 "${HOST_KEY_DIR}"/ssh_host_*_key
    chmod 644 "${HOST_KEY_DIR}"/ssh_host_*_key.pub
}

check_authorized_keys() {
    local f=/etc/ssh/authorized_keys.d/${DEV_USER}
    if [ ! -s "${f}" ]; then
        log "WARNING: ${f} is missing or empty — nobody can log in."
        log "         Run './portal update' on the host to render it from users.yaml."
    else
        log "$(grep -cvE '^\s*(#|$)' "${f}") authorized key(s) mounted from the host"
    fi
}

# ---------------------------------------------------------------------------
# Service: sshd.
# ---------------------------------------------------------------------------
supervise_sshd() {
    mkdir -p /run/sshd
    while :; do
        log "starting sshd"
        /usr/sbin/sshd -D -e
        log "sshd exited (rc=$?); restarting in 2s"
        sleep 2
    done
}

# ---------------------------------------------------------------------------
# Service: the Claude Remote Control loop.
# ---------------------------------------------------------------------------
# Why a loop at all: server mode gives up after roughly ten minutes without
# network, and the container will outlive plenty of those. Re-running
# `claude remote-control` in the SAME directory reattaches the sessions it had
# (for about four hours), which is why the loop never moves out of
# /home/dev/projects and never passes --no-create-session-in-dir.
#
# It runs inside tmux rather than as a bare background process so that a human
# can `ssh` in and `tmux attach -t rc` to see the live TUI — including the
# one-time "Enable Remote Control?" prompt.
rc_loop() {
    cd "${PROJECTS}" || { rc_log "FATAL: ${PROJECTS} is missing"; sleep 60; return 1; }

    local rc
    while :; do
        if [ -f "${RC_PAUSE}" ]; then
            rc_log "paused by 'portal setup'; re-checking in ${RC_AUTH_POLL}s"
            sleep "${RC_AUTH_POLL}"
            continue
        fi

        # Rotate rather than let an unattended container fill its volume.
        if [ -f "${RC_LOG}" ] && [ "$(stat -c %s "${RC_LOG}" 2>/dev/null || echo 0)" -gt "${RC_LOG_MAX}" ]; then
            mv -f "${RC_LOG}" "${RC_LOG}.1"
            rc_log "rotated log"
        fi

        if ! claude auth status >/dev/null 2>&1; then
            rc_log "not signed in to a claude.ai account — run 'portal setup ${AGENT_NAME}' on the host. Re-checking in ${RC_AUTH_POLL}s."
            sleep "${RC_AUTH_POLL}"
            continue
        fi

        rc_log "starting: claude remote-control --name ${AGENT_NAME}@${AGENT_HOST} --spawn worktree (cwd=${PWD})"
        # stdout/stderr split on purpose: stdout stays attached to the tmux pty
        # so the TUI renders and stays interactive, stderr is captured so a
        # crash leaves a trace in rc.log.
        claude remote-control \
            --name "${AGENT_NAME}@${AGENT_HOST}" \
            --spawn worktree \
            2>>"${RC_LOG}"
        rc=$?
        rc_log "exited (rc=${rc}); restarting in ${RC_RESTART_DELAY}s"
        sleep "${RC_RESTART_DELAY}"
    done
}

supervise_rc() {
    while :; do
        if [ -f "${RC_PAUSE}" ]; then
            sleep "${RC_SUPERVISE_POLL}"
            continue
        fi
        if ! as_dev "tmux has-session -t ${RC_SESSION}" >/dev/null 2>&1; then
            log "creating tmux session '${RC_SESSION}'"
            as_dev "tmux new-session -d -s ${RC_SESSION} -c ${PROJECTS} '/usr/local/bin/supervisor.sh rc-loop'" \
                || log "WARNING: could not create tmux session '${RC_SESSION}'"
        fi
        sleep "${RC_SUPERVISE_POLL}"
    done
}

# ---------------------------------------------------------------------------
# Shutdown.
# ---------------------------------------------------------------------------
CHILDREN=()

shutdown() {
    trap '' TERM INT
    log "shutting down"
    local pid
    for pid in "${CHILDREN[@]:-}"; do
        [ -n "${pid}" ] && kill -TERM "-${pid}" 2>/dev/null
    done
    as_dev "tmux kill-server" >/dev/null 2>&1
    pkill -TERM -x sshd 2>/dev/null
    sleep 1
    exit 0
}

# ---------------------------------------------------------------------------
# Entry.
# ---------------------------------------------------------------------------
# Re-entrant: tmux invokes this same script as `supervisor.sh rc-loop` so the
# loop does not need a second file.
case "${1:-supervise}" in
    rc-loop)
        # su -l already rebuilds the environment, but be certain: a single
        # inherited ANTHROPIC_API_KEY here would silently stop every session
        # from appearing.
        scrub_env
        rc_loop
        exit $?
        ;;
    supervise) ;;
    *)
        echo "usage: supervisor.sh [supervise|rc-loop]" >&2
        exit 64
        ;;
esac

scrub_env
log "work container for '${AGENT_NAME}' on host '${AGENT_HOST}'"
seed_home
ensure_host_keys
check_authorized_keys

trap shutdown TERM INT

set -m   # each service in its own process group, so shutdown can signal the tree
supervise_sshd & CHILDREN+=("$!")
if [ "${AGENT_CLAUDE}" = "1" ]; then
    supervise_rc & CHILDREN+=("$!")
else
    log "claude remote control disabled for this user (AGENT_CLAUDE=${AGENT_CLAUDE})"
fi
set +m

log "supervising pids: ${CHILDREN[*]}"
wait
