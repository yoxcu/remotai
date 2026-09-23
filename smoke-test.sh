#!/usr/bin/env bash
#
# smoke-test.sh — end-to-end check of the agent host. RUN THIS ON THE SERVER.
#
#   ./smoke-test.sh
#
# It builds the image, creates a throwaway user called `test` on port 2299,
# and checks the things that actually break in practice:
#
#   * key-only SSH login works, using an authorized_keys file on the host
#   * password auth and root login are refused
#   * claude and codex are on PATH for a NON-login `ssh host 'cmd'` (the way
#     the Codex desktop app spawns app-server) and for a login shell
#   * authorized_keys is synced from the host file and read-only inside
#   * adding a key on the host reaches the container without a restart
#   * an extra_keys entry in users.yaml also gets in
#   * no banned auth/telemetry variable leaks into the container
#   * the container reaches api.anthropic.com and chatgpt.com over HTTPS
#   * the Codex standalone install is shared from the image and linked into
#     the user's ~/.codex, which is what `codex remote-control` insists on
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
ssh-keygen -q -t ed25519 -N '' -f "${KEY}2" -C 'smoke-test-rotated' </dev/null
ssh-keygen -q -t ed25519 -N '' -f "${KEY}3" -C 'smoke-test-extra' </dev/null
# Stand in for a real host account's ~/.ssh/authorized_keys.
HOST_AKEYS="${WORK}/host_authorized_keys"
cp "${KEY}.pub" "${HOST_AKEYS}"

say "1. build agent-base"
if ./portal build --no-pull; then ok "image builds"; else bad "image builds"; exit "${FAIL}"; fi
check_out "claude is installed in the image" '^[0-9]+\.[0-9]+' \
    docker run --rm --entrypoint claude agent-base:latest --version
check_out "codex is installed in the image" 'codex-cli' \
    docker run --rm --entrypoint codex agent-base:latest --version
# `codex remote-control` refuses to run without this exact layout, and the
# image is where it lives so one copy serves every container.
check "the shared standalone codex is in the image" 0 \
    docker run --rm --entrypoint test agent-base:latest \
        -x /opt/codex/packages/standalone/current/bin/codex
check_out "the codex on PATH is that same install" \
    '^/opt/codex/packages/standalone/' \
    docker run --rm --entrypoint readlink agent-base:latest -f /usr/local/bin/codex
check_out "dev user exists with the build uid" '^uid=' \
    docker run --rm --entrypoint id agent-base:latest dev

say "2. portal add ${USER_NAME}"
# --sandbox-mode is set so the check below can follow it all the way through:
# users.yaml -> compose env -> /run/agent.env -> the daemon's command line.
if ./portal add "${USER_NAME}" --authorized-keys "${HOST_AKEYS}" \
        --key "${KEY}3.pub" --claude --codex --port "${PORT}" \
        --sandbox-mode danger-full-access; then
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
check "the host authorized_keys mount is read-only" 1 \
    docker exec "${CONTAINER}" bash -c 'echo x >> /run/host-authorized-keys'
check_out "container authorized_keys is root-owned (StrictModes needs this)" '^root root$' \
    docker exec "${CONTAINER}" stat -c '%U %G' /etc/ssh/authorized_keys.d/dev
check "the extra_keys mount is read-only" 1 \
    docker exec "${CONTAINER}" bash -c 'echo x >> /run/portal-keys/extra'
check_out "both key sources are merged" 'smoke-test-extra' \
    docker exec "${CONTAINER}" cat /etc/ssh/authorized_keys.d/dev

say "5. PATH — the check the Codex desktop app depends on"
# `ssh host 'cmd'` runs bash NON-login and NON-interactive: it reads neither
# /etc/profile nor ~/.bashrc. This is exactly how the app spawns app-server.
check_out "codex on PATH for a non-login ssh command" '^/usr/local/bin/codex$' \
    ssh_cmd 'command -v codex'
check_out "claude on PATH for a non-login ssh command" '^/usr/bin/claude$' \
    ssh_cmd 'command -v claude'
check_out "codex on PATH in a login shell" '^/usr/local/bin/codex$' \
    ssh_cmd 'bash -lc "command -v codex"'
check_out "claude on PATH in a login shell" '^/usr/bin/claude$' \
    ssh_cmd 'bash -lc "command -v claude"'
check_out "codex actually runs over ssh" 'codex-cli' ssh_cmd 'codex --version'

say "6. environment hygiene"
if out=$(ssh_cmd 'env' | grep -E '^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_BASE_URL|DISABLE_TELEMETRY|DO_NOT_TRACK|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC|DISABLE_GROWTHBOOK|CODEX_API_KEY|OPENAI_API_KEY|CODEX_HOME)='); then
    bad "no banned auth/telemetry variables in the container"
    note "${out}"
else
    ok "no banned auth/telemetry variables in the container"
fi
check_out "projects bind mount is writable by dev" '^ok$' \
    ssh_cmd 'touch ~/projects/.smoke && echo ok && rm -f ~/projects/.smoke'

say "6b. outbound network, as the agents see it"
# Any HTTP status means the way out works. A container that cannot get out
# looks healthy by every other check here — and nothing that needs an account
# works. The usual cause is a host firewall restart wiping Docker's rules.
for host in api.anthropic.com chatgpt.com; do
    check_out "container reaches ${host} over HTTPS" '^[1-5][0-9][0-9]$' \
        ssh_cmd "curl -s -m 10 -o /dev/null -w '%{http_code}' https://${host}/"
done

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

say "7b. the codex remote-control daemon"
# Same deal as the claude loop: the throwaway user is not signed in, so the
# poll loop parks in its "not signed in" branch. What this proves is the part
# that is easy to get wrong — that the volume's ~/.codex points at the image's
# standalone install, which is the only thing `codex remote-control` accepts.
check_out "the volume's codex standalone links into the image" \
    '^/opt/codex/packages/standalone$' \
    ssh_cmd 'readlink -f ~/.codex/packages/standalone'
check "the shared standalone install is read-only" 1 \
    ssh_cmd 'touch ~/.codex/packages/standalone/.smoke'
# The daemon is not running (nobody is signed in), so `daemon version` failing
# to reach its socket is the expected answer. What must NOT come back is the
# refusal that means the standalone layout is missing — that is the failure
# this whole arrangement exists to prevent.
out=$(ssh_cmd 'codex app-server daemon version 2>&1')
if printf '%s' "${out}" | grep -q 'standalone Codex install not found'; then
    bad "codex finds the standalone install it demands"
    note "${out%%$'\n'*}"
else
    ok "codex finds the standalone install it demands"
fi
if wait_for 90 ssh_cmd 'grep -q "portal setup" ~/codex.log'; then
    ok "codex.log records the loop waiting for a login"
else
    bad "codex.log records the loop waiting for a login"
    note "$(ssh_cmd 'cat ~/codex.log' 2>&1 | tail -3 | tr '\n' '|')"
fi
# The env-var half of this is easy and proves nothing. What matters is that the
# value reached the command line, across the `su -l` that throws AGENT_* away.
check_out "sandbox_mode reaches the daemon command line" \
    'sandbox_mode=.danger-full-access.' \
    ssh_cmd 'cat ~/codex.log'

check_out "portal status <name> produces its report" '^findings' \
    ./portal status "${USER_NAME}"

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

say "9. both key sources actually authenticate"
# The extra key came from users.yaml, never from the host file.
check "an extra_keys entry from users.yaml can log in" 0 \
    ssh -i "${KEY}3" -p "${PORT}" -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile="${KNOWN}" \
        -o ConnectTimeout=5 -o LogLevel=ERROR -T "dev@${SSH_HOST}" true

say "9b. host-side key rotation"
# The point of host-account passthrough: adding a key on the host must let that
# key in, with no portal command and no restart.
cat "${KEY}2.pub" >> "${HOST_AKEYS}"
rotated=0
deadline=$(( SECONDS + 60 ))
while [ "${SECONDS}" -lt "${deadline}" ]; do
    sleep 3
    if ssh -i "${KEY}2" -p "${PORT}" -o IdentitiesOnly=yes \
           -o StrictHostKeyChecking=no -o UserKnownHostsFile="${KNOWN}" \
           -o ConnectTimeout=5 -o LogLevel=ERROR -T "dev@${SSH_HOST}" true 2>/dev/null; then
        rotated=1; break
    fi
done
if [ "${rotated}" = 1 ]; then
    ok "a key added to the host file works without restarting the container"
else
    bad "a key added to the host file works without restarting the container"
    note "$(docker exec "${CONTAINER}" cat /etc/ssh/authorized_keys.d/dev 2>&1 | tail -2 | tr '\n' '|')"
fi

say "10. persistence across a recreate"
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
