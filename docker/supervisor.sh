#!/usr/bin/env bash
#
# supervisor.sh — PID 1's only child (tini reaps, this supervises).
#
# Runs three things and keeps them running:
#   1. sshd
#   2. if AGENT_CLAUDE=1, a tmux session `rc` holding a restart loop around
#      `claude remote-control`
#   3. if AGENT_CODEX=1, a poll loop around `codex remote-control start`, which
#      keeps the app-server daemon up with remote control enabled so the Codex
#      mobile app can reach this container
#
# The two remote controls have deliberately different shapes because the CLIs
# do. `claude remote-control` is a foreground TUI, so it gets a tmux session a
# human can attach to. `codex remote-control start` starts a detached,
# pid-backed daemon and returns, and is idempotent — so it gets a poll loop and
# there is nothing to attach to.
#
# The Codex DESKTOP app still needs no process here at all: it opens its own SSH
# connection and spawns `codex app-server` through the login shell. That path is
# unchanged and works whether or not the daemon is running.

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
CODEX_LOG="${DEV_HOME}/codex.log"
CODEX_HOME_DIR="${DEV_HOME}/.codex"
# Baked into the image by Dockerfile.agent-base and exported from it, so the
# default here is only a fallback for a hand-run container.
CODEX_SHARED_STANDALONE="${CODEX_SHARED_STANDALONE:-/opt/codex/packages/standalone}"
CODEX_POLL="${CODEX_POLL:-60}"                 # between `codex remote-control start` checks
CODEX_START_TIMEOUT="${CODEX_START_TIMEOUT:-120}"  # ceiling on one of those calls
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
    # Codex remote control: the supervised app-server daemon that the Codex
    # mobile app pairs with. The SSH/desktop-app path needs nothing from us and
    # is available to every container regardless of this.
    AGENT_CODEX="${AGENT_CODEX:-0}"
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
    # Passed to the Codex daemon as `-c sandbox_mode="<mode>"`. Empty means "do
    # not pass it", leaving Codex's own default. This is the Codex counterpart
    # of AGENT_PERMISSION_MODE and has the same scope: it configures the
    # SUPERVISED remote-control daemon, not a `codex` someone runs by hand.
    AGENT_SANDBOX_MODE="${AGENT_SANDBOX_MODE:-}"
    AGENT_WORKDIR="${AGENT_WORKDIR:-${PROJECTS}}"
}

write_agent_env() {
    local tmp="${AGENT_ENV_FILE}.tmp"
    {
        printf 'AGENT_NAME=%q\n'            "${AGENT_NAME}"
        printf 'AGENT_HOST=%q\n'            "${AGENT_HOST}"
        printf 'AGENT_CLAUDE=%q\n'          "${AGENT_CLAUDE}"
        printf 'AGENT_CODEX=%q\n'           "${AGENT_CODEX}"
        printf 'AGENT_SPAWN=%q\n'           "${AGENT_SPAWN}"
        printf 'AGENT_PERMISSION_MODE=%q\n' "${AGENT_PERMISSION_MODE}"
        printf 'AGENT_SANDBOX_MODE=%q\n'     "${AGENT_SANDBOX_MODE}"
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
codex_log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"${CODEX_LOG}"; }

as_dev() { su -l "${DEV_USER}" -c "$1"; }

# ---------------------------------------------------------------------------
# Environment hygiene.
# ---------------------------------------------------------------------------
# Neither remote control works with anything but an account login: Claude's
# needs claude.ai, and Codex refuses outright — "remote control requires ChatGPT
# authentication; API key auth is not supported". Any of these being set — even
# to an empty string, even inherited from the daemon — sends the CLI down an
# API-key or self-hosted code path instead, or trips the nonessential-traffic
# guard. CODEX_HOME is in the list for a different reason: moving it would move
# the standalone install this container links into ~/.codex, and the daemon
# would stop finding it. We never set any of them; this strips anything that
# arrived from outside.
scrub_env() {
    local var found=0
    for var in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
               ANTHROPIC_BASE_URL DISABLE_TELEMETRY DO_NOT_TRACK \
               CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC DISABLE_GROWTHBOOK \
               CODEX_API_KEY OPENAI_API_KEY CODEX_HOME; do
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
    touch "${RC_LOG}" "${CODEX_LOG}"
    chown "${DEV_USER}:${DEV_USER}" "${RC_LOG}" "${CODEX_LOG}"
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
# Service: the Codex remote-control daemon.
# ---------------------------------------------------------------------------
# `codex remote-control` and the whole `codex app-server daemon` family refuse
# to run against the npm package: they want the standalone installer's layout at
# $CODEX_HOME/packages/standalone/current/codex, "because the daemon starts and
# updates app-server from that fixed path".
#
# $CODEX_HOME is ~/.codex, which is the per-user volume, so a literal install
# there would cost ~350MB per user and would auto-update itself out from under
# `portal update`. The image installs it once instead, read-only, and this
# points the volume at it. Verified: the daemon is happy to run from a read-only
# tree — only the auto-updater wants to write, and updates are `portal update`'s
# job.
link_codex_standalone() {
    local link="${CODEX_HOME_DIR}/packages/standalone"

    if [ ! -d "${CODEX_SHARED_STANDALONE}" ]; then
        codex_log "FATAL: ${CODEX_SHARED_STANDALONE} is missing from this image."
        codex_log "  Rebuild it with './portal update' on the host. Until then the Codex"
        codex_log "  desktop app over SSH still works; only mobile remote control does not."
        return 1
    fi

    # Create only what is missing. `install -d` on an EXISTING directory would
    # reset its mode, and ~/.codex holds the OAuth credentials — widening that
    # to whatever default we happened to pass is not ours to do.
    local dir
    for dir in "${CODEX_HOME_DIR}" "${CODEX_HOME_DIR}/packages"; do
        [ -d "${dir}" ] && continue
        install -d -m 0755 -o "${DEV_USER}" -g "${DEV_USER}" "${dir}" 2>/dev/null || true
    done

    if [ -L "${link}" ]; then
        if [ "$(readlink -f "${link}")" = "$(readlink -f "${CODEX_SHARED_STANDALONE}")" ]; then
            return 0
        fi
        ln -sfn "${CODEX_SHARED_STANDALONE}" "${link}"
        chown -h "${DEV_USER}:${DEV_USER}" "${link}" 2>/dev/null || true
        codex_log "re-pointed ${link} at ${CODEX_SHARED_STANDALONE} (image was updated)"
        return 0
    fi

    if [ -e "${link}" ]; then
        # Somebody ran the upstream installer inside the container by hand. That
        # copy works, so do not delete 350MB of someone else's disk — just say
        # what it costs them.
        codex_log "WARNING: ${link} is a real directory, not a link to the image's copy."
        codex_log "  That per-user standalone install auto-updates itself, so this container"
        codex_log "  will drift away from the Codex version 'portal update' pins. To adopt"
        codex_log "  the shared copy: rm -rf ~/.codex/packages/standalone, then restart."
        return 0
    fi

    ln -s "${CODEX_SHARED_STANDALONE}" "${link}"
    chown -h "${DEV_USER}:${DEV_USER}" "${link}" 2>/dev/null || true
    codex_log "linked ${link} -> ${CODEX_SHARED_STANDALONE}"
}

# An unknown sandbox_mode would be passed straight through to Codex and take
# the daemon down on every poll, so check it here the way resolve_spawn does.
# Empty is a valid answer: it means "pass nothing, keep Codex's default".
resolve_sandbox_arg() {
    case "${AGENT_SANDBOX_MODE}" in
        "") return 0 ;;
        read-only|workspace-write|danger-full-access) ;;
        *)
            codex_log "unknown sandbox_mode '${AGENT_SANDBOX_MODE}' — ignoring it and"
            codex_log "  leaving Codex's default (valid: read-only, workspace-write, danger-full-access)"
            return 0
            ;;
    esac
    # The value is whitelisted above, so embedding it in the command string the
    # login shell will run is safe.
    printf " -c 'sandbox_mode=\"%s\"'" "${AGENT_SANDBOX_MODE}"
}

# `codex remote-control start` starts a detached, pid-backed daemon and returns,
# so there is no process to hold open and nothing to attach to — polling it is
# the whole supervision story. It is idempotent ("alreadyRunning") and it also
# re-enables remote control on a daemon that has it off, which makes it the only
# command this loop needs.
#
# Only state CHANGES are logged. At one poll a minute, logging every "connected"
# would bury the one line that matters.
codex_loop() {
    local out state last="" sandbox_arg
    sandbox_arg=$(resolve_sandbox_arg)
    # Logged in full, once, for the same reason rc.log logs its `starting:`
    # line: env vars alone never prove what the process was actually given.
    codex_log "starting: codex remote-control start${sandbox_arg} (sandbox_mode=${AGENT_SANDBOX_MODE:-<codex default>})"
    while :; do
        if [ -f "${RC_PAUSE}" ]; then
            sleep "${CODEX_POLL}"
            continue
        fi

        if [ -f "${CODEX_LOG}" ] && [ "$(stat -c %s "${CODEX_LOG}" 2>/dev/null || echo 0)" -gt "${RC_LOG_MAX}" ]; then
            mv -f "${CODEX_LOG}" "${CODEX_LOG}.1"
            codex_log "rotated log"
            # This loop runs as root, so the file `>>` just recreated is
            # root-owned; seed_home left it to dev and it should stay that way.
            chown "${DEV_USER}:${DEV_USER}" "${CODEX_LOG}" 2>/dev/null || true
            # Only state changes are logged, so a fresh file would otherwise
            # carry no state at all until the next one. Re-announce it.
            last=""
        fi

        if ! as_dev "codex login status" >/dev/null 2>&1; then
            state="not signed in to a ChatGPT account — run 'portal setup ${AGENT_NAME}' on the host"
        else
            # Bounded: `start` has its own internal timeout, but if it ever
            # blocked, an unbounded call here would wedge this loop with no
            # further log lines and nothing to notice it by.
            out=$(as_dev "timeout ${CODEX_START_TIMEOUT} codex remote-control start${sandbox_arg} --json 2>&1")
            # On success this is one JSON object; on failure it is an `Error:`
            # line, and jq gives us nothing to match on.
            state=$(printf '%s\n' "${out}" | jq -r '.status' 2>/dev/null | grep -m1 -v '^null$')
            if [ -z "${state}" ]; then
                state=$(printf '%s\n' "${out}" | grep -m1 . | cut -c1-200)
                [ -n "${state}" ] || state="no output from 'codex remote-control start'"
            fi
        fi

        if [ "${state}" != "${last}" ]; then
            codex_log "${state}"
            last="${state}"
        fi
        sleep "${CODEX_POLL}"
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
    # The daemon is detached, so it outlives this script's process group. Ask it
    # to go away rather than leaving a stale socket for the next boot.
    [ "${AGENT_CODEX:-0}" = "1" ] && as_dev "timeout 10 codex remote-control stop" >/dev/null 2>&1
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
    log "claude remote control: name=${AGENT_NAME}@${AGENT_HOST} spawn=${AGENT_SPAWN}" \
        "workdir=${AGENT_WORKDIR} permission-mode=${AGENT_PERMISSION_MODE:-<claude default>}"
fi
if [ "${AGENT_CODEX}" = "1" ]; then
    # Codex names the device after the hostname, which compose sets to the user
    # name — there is no `--name` to pass, so this is what the phone will show.
    log "codex remote control: device=$(hostname) standalone=${CODEX_SHARED_STANDALONE}" \
        "sandbox-mode=${AGENT_SANDBOX_MODE:-<codex default>}"
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
if [ "${AGENT_CODEX}" = "1" ]; then
    # No standalone install means every poll would fail identically, so say it
    # once here rather than once a minute forever in codex.log.
    if link_codex_standalone; then
        codex_loop & CHILDREN+=("$!")
    else
        log "WARNING: no shared Codex standalone install in this image; codex"
        log "         remote control is off. See ~/codex.log. SSH and the Codex"
        log "         desktop app are unaffected."
    fi
else
    log "codex remote control disabled for this user (AGENT_CODEX=${AGENT_CODEX})"
fi
set +m

log "supervising pids: ${CHILDREN[*]}"
wait
