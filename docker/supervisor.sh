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
RC_HEALTHY_AFTER="${RC_HEALTHY_AFTER:-30}"     # a run this long counts as "it worked"
RC_MAX_DELAY="${RC_MAX_DELAY:-60}"             # ceiling for the failure backoff
RC_LOG_MAX=$(( 8 * 1024 * 1024 ))
# The person's own authorized_keys from their host account, bind-mounted
# read-only. It is staged rather than mounted straight onto the path sshd reads
# because it carries the HOST user's ownership, which is neither root nor `dev`
# inside the container — sshd's StrictModes rejects exactly that. Syncing it to
# a root-owned copy keeps StrictModes on.
HOST_AKEYS="${HOST_AKEYS:-/run/host-authorized-keys}"
# Extra keys rendered by portal from users.yaml, for machines and people with
# no account on this host. Mounted as a DIRECTORY so rewriting the file is
# picked up without recreating the container.
EXTRA_AKEYS="${EXTRA_AKEYS:-/run/portal-keys/extra}"
AKEYS="${AKEYS:-/etc/ssh/authorized_keys.d/dev}"
AKEYS_POLL="${AKEYS_POLL:-15}"

# The rc-loop runs under `su -l dev`, and a LOGIN shell rebuilds the environment
# from scratch: not one AGENT_* variable the container was started with survives
# into it. So the supervisor resolves them once, writes them here, and the
# rc-loop reads them back.
#
# Getting this wrong fails silently and confusingly — every value falls back to
# its default, so the session registers as dev@<container-hostname> with no
# permission mode, and the env vars look perfectly correct from `docker exec`.
AGENT_ENV_FILE="${AGENT_ENV_FILE:-/run/agent.env}"

agent_defaults() {
    AGENT_NAME="${AGENT_NAME:-${DEV_USER}}"
    AGENT_HOST="${AGENT_HOST:-$(hostname)}"
    AGENT_CLAUDE="${AGENT_CLAUDE:-0}"
    # same-dir (default): every session shares the working directory.
    # worktree:  each session gets its own git worktree — REQUIRES the working
    #            directory to be a git repository.
    # session:   one session, capacity 1, exits when complete.
    AGENT_SPAWN="${AGENT_SPAWN:-same-dir}"
    # Passed through to `--permission-mode=`. Empty means "do not pass the flag",
    # leaving Claude Code's own default. bypassPermissions is the "stop asking
    # me" setting: the agent runs tools without prompting, so the container IS
    # the safety boundary.
    AGENT_PERMISSION_MODE="${AGENT_PERMISSION_MODE:-}"
    AGENT_WORKDIR="${AGENT_WORKDIR:-${PROJECTS}}"
}

write_agent_env() {
    local tmp="${AGENT_ENV_FILE}.tmp"
    {
        printf 'AGENT_NAME=%q\n'            "${AGENT_NAME}"
        printf 'AGENT_HOST=%q\n'            "${AGENT_HOST}"
        printf 'AGENT_CLAUDE=%q\n'          "${AGENT_CLAUDE}"
        printf 'AGENT_SPAWN=%q\n'           "${AGENT_SPAWN}"
        printf 'AGENT_PERMISSION_MODE=%q\n' "${AGENT_PERMISSION_MODE}"
        printf 'AGENT_WORKDIR=%q\n'         "${AGENT_WORKDIR}"
    } >"${tmp}" && mv -f "${tmp}" "${AGENT_ENV_FILE}"
    chmod 0644 "${AGENT_ENV_FILE}" 2>/dev/null || true
}

read_agent_env() {
    [ -r "${AGENT_ENV_FILE}" ] || return 0
    # shellcheck source=/dev/null
    . "${AGENT_ENV_FILE}"
}

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

# Copy the host account's authorized_keys into place if it has changed.
# Picks up in-place edits (`>>`, `ssh-copy-id`, most editors) within AKEYS_POLL
# seconds. If the file is REPLACED with a new inode, the bind mount still points
# at the old one and the container has to be restarted — see docs/ADMIN.md.
sync_authorized_keys() {
    local tmp sources=""
    tmp=$(mktemp) || return 1

    if [ -f "${HOST_AKEYS}" ]; then
        printf '# --- from the host account ---\n' >>"${tmp}"
        cat "${HOST_AKEYS}" >>"${tmp}"
        printf '\n' >>"${tmp}"
        sources="host account"
    fi
    if [ -f "${EXTRA_AKEYS}" ]; then
        printf '# --- extra_keys from users.yaml ---\n' >>"${tmp}"
        cat "${EXTRA_AKEYS}" >>"${tmp}"
        sources="${sources:+${sources} + }users.yaml"
    fi
    if [ -z "${sources}" ]; then
        rm -f "${tmp}"
        return 1
    fi

    if cmp -s "${tmp}" "${AKEYS}" 2>/dev/null; then
        rm -f "${tmp}"
        return 0
    fi
    mkdir -p "$(dirname "${AKEYS}")"
    if ! install -m 0644 -o root -g root "${tmp}" "${AKEYS}"; then
        rm -f "${tmp}"
        return 1
    fi
    rm -f "${tmp}"
    log "authorized_keys synced from ${sources} ($(count_keys) key(s))"
    return 0
}

# Actual keys, not lines: a file of nothing but comments is still unusable.
count_keys() {
    # grep -c prints 0 AND exits 1 when nothing matches, so take the exit
    # status as the signal and never append a second value.
    local n
    n=$(grep -cvE '^[[:space:]]*(#|$)' "${AKEYS}" 2>/dev/null) || n=0
    printf '%s' "${n:-0}"
}

check_authorized_keys() {
    if ! sync_authorized_keys; then
        log "WARNING: neither ${HOST_AKEYS} nor ${EXTRA_AKEYS} is mounted —"
        log "         nobody can log in. Check the host account's"
        log "         ~/.ssh/authorized_keys exists, then run './portal update'."
        return
    fi
    if [ "$(count_keys)" -eq 0 ]; then
        log "WARNING: no keys from any source — nobody can log in."
        log "         Add one to the host account's ~/.ssh/authorized_keys, or to"
        log "         extra_keys in users.yaml then './portal render'. Either is"
        log "         picked up within ${AKEYS_POLL}s; no restart needed."
    fi
}

supervise_authorized_keys() {
    while :; do
        sleep "${AKEYS_POLL}"
        sync_authorized_keys >/dev/null 2>&1
    done
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
# `--spawn worktree` is a hard error when the working directory is not a git
# repository — Claude Code only falls back silently for a SAVED spawn mode, not
# for an explicit flag. Without this check the loop would exit rc=1 every five
# seconds forever.
resolve_spawn() {
    local want="${AGENT_SPAWN}"
    case "${want}" in
        same-dir|worktree|session) ;;
        *)
            rc_log "unknown spawn mode '${want}' — using same-dir (valid: same-dir, worktree, session)"
            want=same-dir
            ;;
    esac
    if [ "${want}" = worktree ] && ! git -C "${AGENT_WORKDIR}" rev-parse --git-dir >/dev/null 2>&1; then
        rc_log "spawn mode 'worktree' needs ${AGENT_WORKDIR} to be a git repository, and it is not — using same-dir instead."
        rc_log "  To get worktree mode, point this user at a repo: set 'workdir:' in users.yaml."
        want=same-dir
    fi
    printf '%s' "${want}"
}

rc_loop() {
    cd "${AGENT_WORKDIR}" || { rc_log "FATAL: ${AGENT_WORKDIR} is missing"; sleep 60; return 1; }

    local rc spawn started elapsed delay="${RC_RESTART_DELAY}"
    local -a perm_args=()
    spawn=$(resolve_spawn)
    if [ -n "${AGENT_PERMISSION_MODE}" ]; then
        perm_args=("--permission-mode=${AGENT_PERMISSION_MODE}")
    fi
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

        rc_log "starting: claude remote-control --name ${AGENT_NAME}@${AGENT_HOST} --spawn ${spawn} ${perm_args[*]:-} (cwd=${PWD})"
        # stdout/stderr split on purpose: stdout stays attached to the tmux pty
        # so the TUI renders and stays interactive, stderr is captured so a
        # crash leaves a trace in rc.log.
        started=${SECONDS}
        claude remote-control \
            --name "${AGENT_NAME}@${AGENT_HOST}" \
            --spawn "${spawn}" \
            "${perm_args[@]}" \
            2>>"${RC_LOG}"
        rc=$?
        elapsed=$(( SECONDS - started ))

        # A network drop after a healthy run restarts promptly, as intended. A
        # run that dies immediately is a misconfiguration, and hammering it
        # every 5s just floods the log — back off instead.
        if [ "${elapsed}" -lt "${RC_HEALTHY_AFTER}" ]; then
            delay=$(( delay * 2 ))
            [ "${delay}" -gt "${RC_MAX_DELAY}" ] && delay="${RC_MAX_DELAY}"
            rc_log "exited after ${elapsed}s (rc=${rc}) — looks like a misconfiguration; retrying in ${delay}s"
        else
            delay="${RC_RESTART_DELAY}"
            rc_log "exited after ${elapsed}s (rc=${rc}); restarting in ${delay}s"
        fi
        sleep "${delay}"
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
            as_dev "tmux new-session -d -s ${RC_SESSION} -c ${AGENT_WORKDIR} '/usr/local/bin/supervisor.sh rc-loop'" \
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
        # Read back what the supervisor resolved; `su -l` threw the real
        # environment away on the way in.
        read_agent_env
        agent_defaults
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

agent_defaults
scrub_env
write_agent_env
log "work container for '${AGENT_NAME}' on host '${AGENT_HOST}'"
if [ "${AGENT_CLAUDE}" = "1" ]; then
    log "remote control: name=${AGENT_NAME}@${AGENT_HOST} spawn=${AGENT_SPAWN}" \
        "workdir=${AGENT_WORKDIR} permission-mode=${AGENT_PERMISSION_MODE:-<claude default>}"
fi
seed_home
ensure_host_keys
check_authorized_keys

trap shutdown TERM INT

set -m   # each service in its own process group, so shutdown can signal the tree
supervise_sshd & CHILDREN+=("$!")
supervise_authorized_keys & CHILDREN+=("$!")
if [ "${AGENT_CLAUDE}" = "1" ]; then
    supervise_rc & CHILDREN+=("$!")
else
    log "claude remote control disabled for this user (AGENT_CLAUDE=${AGENT_CLAUDE})"
fi
set +m

log "supervising pids: ${CHILDREN[*]}"
wait
