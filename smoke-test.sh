#!/usr/bin/env bash
#
# smoke-test.sh — end-to-end check of the agent host. RUN THIS ON THE SERVER.
#
#   ./smoke-test.sh
#
# It builds the image, creates a throwaway user called `test` on port 2299,
# and checks the things that actually break in practice:
#
#   * key-only SSH login works
#   * password auth and root login are refused
#   * claude and codex are on PATH for a NON-login `ssh host 'cmd'` (the way
#     the Codex desktop app spawns app-server) and for a login shell
#   * authorized_keys is read-only inside the container
#   * no banned auth/telemetry variable leaks into the container
#   * the supervisor restarts the remote-control loop when it is killed,
#     and restarts sshd when that is killed
#
# It then removes the user and restores users.yaml. Existing users are never
# touched: nothing here rebuilds or recreates their containers.
#
# Exit status is the number of failed checks (0 = all good).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

USER_NAME=test
PORT=2299
SSH_HOST=127.0.0.1
WORK="${ROOT}/.smoke"
KEY="${WORK}/id_ed25519"
KNOWN="${WORK}/known_hosts"
CONTAINER="work-${USER_NAME}"
BACKUP="${WORK}/users.yaml.bak"
HAD_USERS_YAML=0

PASS=0
FAIL=0

# ---------------------------------------------------------------------------

say()  { printf '\n\033[1;36m── %s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '   \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '   \033[31mFAIL\033[0m %s\n' "$*"; }
note() { printf '        \033[2m%s\033[0m\n' "$*"; }

# check <description> <expected-rc> <command...>
check() {
    local desc=$1 want=$2; shift 2
    local out rc
    out=$("$@" 2>&1); rc=$?
    if [ "${rc}" -eq "${want}" ]; then
        ok "${desc}"
    else
        bad "${desc} (exit ${rc}, wanted ${want})"
        [ -n "${out}" ] && note "${out%%$'\n'*}"
    fi
}

# check_out <description> <regex> <command...>
check_out() {
    local desc=$1 want=$2; shift 2
    local out
    out=$("$@" 2>&1)
    if printf '%s' "${out}" | grep -qE "${want}"; then
        ok "${desc}"
    else
        bad "${desc} (output did not match /${want}/)"
        [ -n "${out}" ] && note "${out%%$'\n'*}"
    fi
}

ssh_cmd() {
    ssh -i "${KEY}" -p "${PORT}" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile="${KNOWN}" \
        -o ConnectTimeout=5 \
        -o LogLevel=ERROR \
        -T "dev@${SSH_HOST}" "$@"
}

wait_for() {   # wait_for <seconds> <command...>
    local deadline=$(( SECONDS + $1 )); shift
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        "$@" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

cleanup() {
    say "cleanup"
    if ./portal status -q 2>/dev/null | grep -q "^${USER_NAME} "; then
        ./portal rm "${USER_NAME}" --purge --yes >/dev/null 2>&1 \
            && echo "   removed ${CONTAINER}, volume and /srv/agents/${USER_NAME}" \
            || echo "   (nothing to remove)"
    fi
    if [ "${HAD_USERS_YAML}" = 1 ] && [ -f "${BACKUP}" ]; then
        mv -f "${BACKUP}" "${ROOT}/users.yaml"
        ./portal render >/dev/null 2>&1
        echo "   restored users.yaml"
    elif [ "${HAD_USERS_YAML}" = 0 ]; then
        # There was no users.yaml before this run; do not leave one behind.
        rm -f "${ROOT}/users.yaml" "${ROOT}/compose.users.yml"
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------

say "preflight"
for bin in docker ssh ssh-keygen python3; do
    command -v "${bin}" >/dev/null || { echo "missing: ${bin}"; exit 99; }
done
if ! err=$(python3 -c 'import yaml' 2>&1); then
    echo "python3 cannot import yaml:"
    echo "   interpreter: $(command -v python3) ($(python3 -V 2>&1))"
    echo "   ${err##*$'\n'}"
    echo "   install it:  pacman -S python-yaml | apt-get install python3-yaml | pip install PyYAML"
    echo "   note: if python3 is a venv/pyenv/conda build, the distro package"
    echo "         will not be visible to it — install into that interpreter,"
    echo "         or run with a system python: /usr/bin/python3 ./portal ..."
    exit 99
fi
docker compose version >/dev/null 2>&1 || { echo "missing: docker compose v2"; exit 99; }
if [ -f users.yaml ] && grep -qE "^\s*-?\s*name:\s*${USER_NAME}\s*$" users.yaml; then
    echo "refusing to run: a real user called '${USER_NAME}' already exists in users.yaml"
    exit 99
fi
if ss -ltn 2>/dev/null | grep -q ":${PORT}\b"; then
    echo "refusing to run: port ${PORT} is already in use"
    exit 99
fi
echo "   ok"

mkdir -p "${WORK}"
if [ -f users.yaml ]; then HAD_USERS_YAML=1; cp -a users.yaml "${BACKUP}"; fi
ssh-keygen -q -t ed25519 -N '' -f "${KEY}" -C 'smoke-test' </dev/null

say "1. build agent-base"
if ./portal build --no-pull; then ok "image builds"; else bad "image builds"; exit "${FAIL}"; fi
check_out "claude is installed in the image" '^[0-9]+\.[0-9]+' \
    docker run --rm --entrypoint claude agent-base:latest --version
check_out "codex is installed in the image" 'codex-cli' \
    docker run --rm --entrypoint codex agent-base:latest --version
check_out "dev user exists with the build uid" '^uid=' \
    docker run --rm --entrypoint id agent-base:latest dev

say "2. portal add ${USER_NAME}"
if ./portal add "${USER_NAME}" --key "${KEY}.pub" --claude --codex --port "${PORT}"; then
    ok "portal add"
else
    bad "portal add"; exit "${FAIL}"
fi
check "container is running" 0 \
    docker inspect -f '{{.State.Running}}' "${CONTAINER}"

say "3. sshd, key login"
if wait_for 60 ssh_cmd true; then
    ok "key-based login works on port ${PORT}"
else
    bad "key-based login works on port ${PORT}"
    note "$(docker logs --tail 20 "${CONTAINER}" 2>&1 | tr '\n' '|')"
fi
check_out "logged in as dev" '^dev$' ssh_cmd 'whoami'
check_out "host keys came from the home volume" 'host_keys' \
    docker exec "${CONTAINER}" sshd -T -f /etc/ssh/sshd_config

say "4. sshd refuses what it should"
check "password auth refused" 255 \
    ssh -p "${PORT}" -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile="${KNOWN}" \
        -o ConnectTimeout=5 -o LogLevel=ERROR -o BatchMode=yes \
        -T "dev@${SSH_HOST}" true
check "root login refused" 255 \
    ssh -i "${KEY}" -p "${PORT}" -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile="${KNOWN}" \
        -o ConnectTimeout=5 -o LogLevel=ERROR \
        -T "root@${SSH_HOST}" true
check "authorized_keys is read-only in the container" 1 \
    docker exec "${CONTAINER}" bash -c 'echo x >> /etc/ssh/authorized_keys.d/dev'

say "5. PATH — the check the Codex desktop app depends on"
# `ssh host 'cmd'` runs bash NON-login and NON-interactive: it reads neither
# /etc/profile nor ~/.bashrc. This is exactly how the app spawns app-server.
check_out "codex on PATH for a non-login ssh command" '^/usr/bin/codex$' \
    ssh_cmd 'command -v codex'
check_out "claude on PATH for a non-login ssh command" '^/usr/bin/claude$' \
    ssh_cmd 'command -v claude'
check_out "codex on PATH in a login shell" '^/usr/bin/codex$' \
    ssh_cmd 'bash -lc "command -v codex"'
check_out "claude on PATH in a login shell" '^/usr/bin/claude$' \
    ssh_cmd 'bash -lc "command -v claude"'
check_out "codex actually runs over ssh" 'codex-cli' ssh_cmd 'codex --version'

say "6. environment hygiene"
if out=$(ssh_cmd 'env' | grep -E '^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_BASE_URL|DISABLE_TELEMETRY|DO_NOT_TRACK|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC|DISABLE_GROWTHBOOK)='); then
    bad "no banned auth/telemetry variables in the container"
    note "${out}"
else
    ok "no banned auth/telemetry variables in the container"
fi
check_out "projects bind mount is writable by dev" '^ok$' \
    ssh_cmd 'touch ~/projects/.smoke && echo ok && rm -f ~/projects/.smoke'

say "7. the supervised remote-control loop"
# The throwaway user is deliberately not signed in, so the loop parks in its
# "not signed in — run portal setup" branch. That still exercises every piece
# of the supervision: the tmux session, the inner restart loop and rc.log.
if wait_for 60 ssh_cmd 'tmux has-session -t rc'; then
    ok "tmux session 'rc' is up"
else
    bad "tmux session 'rc' is up"
fi
check_out "loop runs in /home/dev/projects" '/home/dev/projects' \
    ssh_cmd 'tmux display-message -p -t rc "#{pane_current_path}"'
check_out "rc.log records the loop waiting for a login" 'portal setup' \
    ssh_cmd 'cat ~/rc.log'

say "8. supervisor restarts what dies"
before=$(ssh_cmd 'wc -l < ~/rc.log' 2>/dev/null | tr -d ' \r')
ssh_cmd 'pkill -f "supervisor[.]sh rc-loop"' >/dev/null 2>&1
restarted=0
deadline=$(( SECONDS + 90 ))
while [ "${SECONDS}" -lt "${deadline}" ]; do
    sleep 3
    ssh_cmd 'tmux has-session -t rc' >/dev/null 2>&1 || continue
    after=$(ssh_cmd 'wc -l < ~/rc.log' 2>/dev/null | tr -d ' \r')
    if [ -n "${after}" ] && [ "${after}" -gt "${before:-0}" ]; then restarted=1; break; fi
done
if [ "${restarted}" = 1 ]; then
    ok "killed rc loop is restarted and rc.log keeps growing"
    note "rc.log ${before:-0} -> ${after} lines"
else
    bad "killed rc loop is restarted and rc.log keeps growing"
    note "rc.log before=${before:-?} after=${after:-?}"
fi

docker exec -u dev "${CONTAINER}" tmux kill-server >/dev/null 2>&1
if wait_for 90 ssh_cmd 'tmux has-session -t rc'; then
    ok "killed tmux server is recreated by the supervisor"
else
    bad "killed tmux server is recreated by the supervisor"
fi

docker exec "${CONTAINER}" pkill -x sshd >/dev/null 2>&1
if wait_for 60 ssh_cmd true; then
    ok "killed sshd is restarted by the supervisor"
else
    bad "killed sshd is restarted by the supervisor"
fi
check "container never restarted (supervisor handled it in-process)" 0 \
    bash -c "[ \"\$(docker inspect -f '{{.RestartCount}}' ${CONTAINER})\" = 0 ]"

say "9. persistence across a recreate"
marker="smoke-$(date +%s)"
ssh_cmd "echo ${marker} > ~/.smoke-marker" >/dev/null 2>&1
docker compose -f docker-compose.yml -f compose.users.yml up -d --force-recreate "${CONTAINER}" >/dev/null 2>&1
if wait_for 60 ssh_cmd true; then
    check_out "home volume survives --force-recreate" "${marker}" ssh_cmd 'cat ~/.smoke-marker'
    check "ssh host key is unchanged after recreate" 0 \
        ssh -i "${KEY}" -p "${PORT}" -o IdentitiesOnly=yes \
            -o StrictHostKeyChecking=yes -o UserKnownHostsFile="${KNOWN}" \
            -o ConnectTimeout=5 -o LogLevel=ERROR -T "dev@${SSH_HOST}" true
else
    bad "container comes back after --force-recreate"
    bad "ssh host key is unchanged after recreate"
fi

# ---------------------------------------------------------------------------

say "result"
printf '   %d passed, %d failed\n' "${PASS}" "${FAIL}"
exit "${FAIL}"
