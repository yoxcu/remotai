# Admin guide

One Docker image, one container per person, one `users.yaml`.

```
users.yaml  ──portal──▶  compose.users.yml   (containers)

/home/<name>/.ssh/authorized_keys  ──bind,ro──▶  work-<name>
```

Each container accepts two sets of keys, concatenated by `supervisor.sh`:

- **`authorized_keys:`** — a file on the host, mounted read-only. Normally the
  person's own `~/.ssh/authorized_keys`, so rotating a key on the host rotates
  it in the container.
- **`extra_keys:`** — keys listed in `users.yaml`, for machines or people with
  no account on this host.

Either may be omitted, but not both. Both are picked up within ~15s; no restart.
No container is given the Docker socket.

## Requirements

- Docker Engine with the Compose v2 plugin
- Python 3 with PyYAML — `pacman -S python-yaml` (Arch/Manjaro),
  `apt-get install -y python3-yaml` (Debian/Ubuntu), or `pip install PyYAML`.
  It must be importable by whichever `python3` is first on your PATH.
- A user who can talk to Docker, and who can write `/srv/agents`

## First run

```sh
cp users.yaml.example users.yaml      # optional; `portal add` creates it too
./portal update                       # builds agent-base:latest
```

The image bakes in the UID/GID that `portal` is running as, so bind-mounted
projects are writable from both sides. Under `sudo` it uses `SUDO_UID`/`SUDO_GID`
— your own account, not root — and a true root shell falls back to 1000. Pin it
explicitly with `uid:`/`gid:` in `users.yaml` if more than one person runs
`portal`, since changing it rebuilds the image.

`portal` needs to write `srv_root` (`/srv/agents` by default). Either run it with
`sudo`, or hand yourself the directory once and run it as yourself:

```sh
sudo install -d -o "$USER" -g "$USER" /srv/agents
sudo usermod -aG docker "$USER"      # log out and back in
```

---

## Adding a user

Alice needs a **host account** with a populated `~/.ssh/authorized_keys` — the
same file she already uses to SSH into this server:

```sh
./portal add alice --claude --codex
```

That resolves `/home/alice/.ssh/authorized_keys`, records the path in
`users.yaml`, creates `/srv/agents/alice/projects`, and starts `work-alice`. The
port is auto-assigned from 2201 upward; pass `--port` to pin one.

Add extra keys at the same time, or instead:

```sh
# host account's keys PLUS one more
./portal add alice --claude --key ~/keys/alice-work.pub

# different host account
./portal add alice --host-user a.smith --claude

# a file that is not a host account's
./portal add ci --authorized-keys /etc/ci/keys --codex

# no host account at all
./portal add ci --no-host-keys --key ~/keys/ci.pub --codex
```

`--key` takes a literal key, a path to a `.pub` file, or `-` for stdin, and is
repeatable. If there is no matching host account and you gave `--key`, `portal`
warns and carries on with just those.

`portal add` refuses if the file does not exist, rather than letting Docker
create a *directory* called `authorized_keys` inside somebody's `~/.ssh`.

Then, **with Alice present** (every step needs someone at a browser):

```sh
./portal setup alice
```

It walks through, in order:

1. `claude auth login` — prints a URL, Alice approves it and pastes the code
   back. This is the only login Remote Control accepts. Not `claude
   setup-token`, not an API key.
2. Running `claude` once in `/home/dev/projects` to accept the workspace trust
   prompt. Claude Code never persists trust for `$HOME`, which is exactly why
   the server runs from `~/projects` and not from the home directory.
3. Running `claude remote-control` once to answer **"Enable Remote Control?"**.
4. Codex login, which offers a choice because Codex has no headless flow of its
   own. `codex login` serves an OAuth callback on `localhost:1455` and wants a
   browser there:
   - **SSH tunnel** (default, works everywhere): Alice runs
     `ssh -L 1455:localhost:1455 -p 2201 dev@<server>` from her own machine and
     then `codex login` inside that session. The tunnel must terminate *in the
     container* — the container has its own network namespace, so `docker exec`
     cannot carry the callback.
   - **`--device-auth`**: no tunnel, but many ChatGPT workspaces disable it and
     answer `Please contact your workspace admin to enable device code
     authentication`.
   - If both are impossible, `portal setup` prints the last-resort `scp` of
     `~/.codex/auth.json` from a machine where she is already signed in. It
     carries the refresh token so it keeps working, but it ties the container to
     that same install.
5. Codex pairing: it brings the app-server daemon up with remote control
   enabled and prints a short-lived code for Alice's phone. Her phone may well
   have picked the container up already — it enrolls under the account she just
   signed in as — so this is the manual fallback, and it is repeatable any time
   with `./portal pair alice`.
6. Restarting the container so the supervised loops take over.

While setup runs, `portal` drops `/home/dev/.rc-paused` so the background loop
does not fight it for the same directory. It is removed afterwards even if you
Ctrl-C out.

Finally, send Alice `USER-CLAUDE.md` and `USER-CODEX.md` with her port filled
in.

### Checking on things

```sh
./portal status        # container state + both logins + both remote controls
./portal status -q     # skip the in-container probes (instant)
./portal status alice  # one user in depth, ending in a list of findings
```

| Column | What it is |
|---|---|
| `CLAUDE` | the claude.ai login, by auth method. `NO LOGIN` means the loop is idling — rerun `portal setup`. |
| `LOOP` | the tmux session holding `claude remote-control`. |
| `CODEX` | the ChatGPT login. |
| `DAEMON` | the Codex app-server daemon. `up` = running with remote control on; `no-rc` = running but not reachable from a phone; `orphan` = an app-server is running but the daemon has lost track of it (see Troubleshooting); `down` = not running. |
| `SANDBOX` | the Codex `sandbox_mode`, or `default` for Codex's own. |

The last line of each user's `~/rc.log` and `~/codex.log` is printed below the
table. `status` only ever reads — it asks the Codex daemon its version rather
than running `remote-control start`, so checking never starts anything.

`./portal status <name>` is the first thing to run when one person says "it
stopped working". In one go it shows:

- the container, and whether its image is older than `agent-base:latest`
- the settings it is running with, and any drift from `users.yaml`
- CPU, memory and pids
- **outbound HTTPS from inside the container**
- both agents in detail: the Codex daemon's pid files and processes, and the
  tails of `rc.log`, `codex.log` and Codex's own stderr log

It ends with a list of findings, each saying what to do. The network check is
the one to look at first. A container that cannot get out looks healthy
everywhere else: logged in, daemon up, loop running, and yet nothing works.

---

## Codex on a phone

`codex: true` gets a user two things off one login: the desktop app over SSH, as
before, and a supervised `codex remote-control` daemon so the container turns up
in the Codex phone app. Nothing is exposed inbound either way — the daemon dials
out.

```sh
./portal pair alice     # short-lived pairing code, repeatable
```

The daemon enrolls under whichever ChatGPT account the container is signed in
as, so a phone on that same account often lists the container without pairing at
all. `portal pair` is the manual route.

Codex names the device after the container's **hostname**, which is the user
name. There is no `--name` flag, so unlike Claude there is no
`alice@agents.example.com` form — the phone just says `alice`. If you run more
than one agent host, give containers distinct names across them.

### Where the Codex binary lives, and why it is not npm

`codex remote-control`, and every `codex app-server daemon` subcommand, refuses
to run against the npm package:

```
Error: managed standalone Codex install not found at
       $CODEX_HOME/packages/standalone/current/codex
This command requires the standalone install managed by the Codex installer,
because the daemon starts and updates app-server from that fixed path.
```

`$CODEX_HOME` is `~/.codex` — a **per-user volume** here. Installing it there
would put ~350MB in every volume and hand each container an auto-updater that
moves Codex whenever it likes, behind `portal update`'s back.

So the image installs it once, at `/opt/codex/packages/standalone`, root-owned
and read-only, and `supervisor.sh` symlinks each user's
`~/.codex/packages/standalone` at it on boot. The daemon runs fine from a
read-only tree; only the auto-updater wants to write, and moving versions is
`portal update`'s job. One consequence worth knowing: `codex` is now
`/usr/local/bin/codex`, not `/usr/bin/codex`.

If someone runs the upstream installer inside their own container by hand, that
real directory wins and `supervisor.sh` leaves it alone — but it says so in
`~/codex.log`, because that container will then drift off the pinned version.
`rm -rf ~/.codex/packages/standalone` and a restart adopts the shared copy
again.

---

## Updating

```sh
./portal update
```

Rebuilds `agent-base:latest` with a fresh `npm install -g` of
`@anthropic-ai/claude-code` and a fresh run of the Codex standalone installer,
then recreates every container. Both agent layers move together.

**Nothing is lost.** Each `<name>-home` named volume is reattached to the new
container, so logins, `~/.claude`, `~/.codex`, `~/.ssh`, shell history and the
sshd host keys all survive. Users will not have to log in again and will not get
a host-key warning.

What *is* lost: anything a user `sudo apt install`ed at runtime. Durable tools
belong in `docker/toolchain.hook.sh`, which is rebuilt into the image. That hook
sits above the npm layer, so `portal update` re-pulls the agents without
re-running your toolchain, and editing the hook costs one npm install.

`--no-pull` rebuilds without forcing fresh agent downloads, if you want to change
the image without moving versions.

Because Codex lives in the image rather than in anyone's volume, `portal update`
moves every container to the same Codex at once — there is no per-container
drift to chase.

Do this on a weekday morning, not mid-sprint: recreating a container interrupts
whatever sessions were running. They come back, but the work in flight does not.

---

## Spawn modes

`claude remote-control --spawn <mode>` decides how each new session gets a
working tree:

| mode | behaviour |
|---|---|
| `same-dir` | **default.** Every session shares `workdir`. Right for `/home/dev/projects`, which holds repos but is not one. |
| `worktree` | Each session gets its own git worktree. **`workdir` must be a git repository** or Claude Code exits immediately. |
| `session` | One session, capacity 1, exits when complete. |

Claude Code falls back to `same-dir` on its own only for a *saved* spawn mode;
an explicit `--spawn worktree` against a non-repo is a hard error. `supervisor.sh`
therefore checks `git rev-parse` first and falls back with a line in `rc.log`
rather than exiting every few seconds.

To give someone real worktree isolation, point them at a repo:

```sh
./portal add alice --claude --spawn worktree --workdir /home/dev/projects/monorepo
```

Or for an existing user, set `spawn:` and `workdir:` in `users.yaml` and run
`./portal update`.

---

## Permission mode

By default Claude Code asks before it runs tools. To let an agent work
unattended — which is rather the point of a Remote Control host — set a
permission mode:

```sh
./portal add alice --claude --skip-permissions          # = bypassPermissions
./portal add alice --claude --permission-mode acceptEdits
```

Or `permission_mode:` in `users.yaml` for an existing user, then
`./portal update`. Valid modes: `default`, `acceptEdits`, `auto`,
`bypassPermissions`, `manual`, `dontAsk`, `plan`. Omitting it passes no flag at
all, leaving Claude Code's default.

Note `remote-control` does **not** accept `--dangerously-skip-permissions` —
that flag belongs to the main CLI. `--permission-mode=bypassPermissions` is the
equivalent here, and it is what `--skip-permissions` sets.

Be clear-eyed about `bypassPermissions` on this host: the agent runs commands
without asking, in a container that has network access and passwordless sudo.
The container boundary is then the only thing between it and your server. That
is a reasonable trade for a per-person sandbox — it is not a reasonable trade if
you have mounted anything sensitive into `/srv/agents`.

`remote-control` also accepts `--sandbox`, which is a separate hardening knob
and not currently wired through `portal`. Ask if you want it.

---

## Codex sandbox mode

The Codex counterpart of `permission_mode`, and it has the same scope: it
configures the **supervised remote-control daemon** — the sessions that come
from someone's phone — not a `codex` they run by hand over SSH.

```sh
./portal add alice --codex --sandbox-mode danger-full-access
```

Or `sandbox_mode:` in `users.yaml` for an existing user, then `./portal update`.
Valid modes: `read-only`, `workspace-write`, `danger-full-access`. Omitting it
passes nothing, leaving Codex's own default — `workspace-write` with approval
`OnRequest`.

`supervisor.sh` passes it as `-c sandbox_mode="<mode>"` on
`codex remote-control start`, and logs the full command in `~/codex.log` at
boot, so you can see what the daemon was actually given rather than inferring it
from environment variables:

```
starting: codex remote-control start -c 'sandbox_mode="danger-full-access"' (sandbox_mode=danger-full-access)
```

`portal pair` passes the same flag, so a pairing that happens to find the daemon
down does not start one configured differently from every daemon the supervisor
starts.

### Whether the sandbox works here at all

Codex's Linux sandbox is bubblewrap-based, and bubblewrap needs unprivileged
user namespaces. Docker's default seccomp and AppArmor confinement denies those
inside a container — **even when the host allows them**, which is the confusing
part. Check your own containers:

```sh
docker exec -u dev work-alice codex sandbox -- sh -c 'echo ok'
```

- prints `ok` → the sandbox engages, and there is nothing to configure.
- prints `bwrap: No permissions to create a new namespace…` → it cannot work
  here. It does not degrade to running unsandboxed; it fails.

If it fails, confirm what that means for real sessions, which take a different
code path from that subcommand:

```sh
docker exec -it work-alice su -l dev -c "codex exec 'Run the shell command: echo PROBE'"
```

If that fails the same way, every shell command from a phone will, and
`sandbox_mode: danger-full-access` is what makes the container usable.

### Why `danger-full-access` is usually the honest answer here

The name is alarming and the trade is not. Three things are already true of
these containers:

- everyone in one has **passwordless sudo**;
- Claude runs with `bypassPermissions` wherever you have set it;
- this guide already says, above, that the container is the security boundary.

An inner Codex sandbox on top of that prevents accidents, not a determined
agent. And the alternative — `security_opt: [apparmor=unconfined]` or
`seccomp=unconfined` on the containers, so bubblewrap can nest — buys the inner
sandbox by weakening the outer one you actually rely on. That is a bad trade.
Flipping the host sysctl is worse still: it affects every container and every
process on the box.

So: if the check above fails, set `sandbox_mode: danger-full-access` and treat
the container as the boundary, which is what it already was.

---

## Rotating and revoking keys

**A key the person controls.** Nothing to run: Alice edits
`~/.ssh/authorized_keys` on the host and the container picks it up within about
15 seconds.

**A key you control.** Edit `extra_keys:` in `users.yaml` and re-render — no
rebuild, no restart, no interrupted sessions:

```sh
$EDITOR users.yaml
./portal render
```

Both work the same way underneath: `supervisor.sh` polls the two read-only
mounts and concatenates them into a root-owned file that sshd reads. (The copy
exists because the host file carries Alice's host UID, which is neither root nor
`dev` inside the container, and sshd's `StrictModes` rejects exactly that.)

One caveat, and it applies only to the host file: that bind mount follows the
file's **inode**. Appending (`>>`, `ssh-copy-id`, most editors) is picked up
live; a tool that writes a replacement and renames it over the top is not, and
the container keeps reading the old inode until `docker restart work-alice`.
`extra_keys` is immune — portal's directory is mounted as a directory.

```sh
docker exec work-alice cat /etc/ssh/authorized_keys.d/dev   # what sshd sees
docker logs work-alice | grep authorized_keys               # sync history
```

---

## Removing a user

```sh
./portal rm alice             # stops the container, keeps their data
./portal rm alice --purge     # also deletes alice-home and /srv/agents/alice
```

Plain `rm` is reversible: re-adding Alice with the same name reattaches the same
volume and her logins are still there. `--purge` is not reversible and asks
twice.

---

## Backups

Two things per user, and they have very different sensitivities.

**`/srv/agents/<name>/projects`** — ordinary files on your disk. Back up however
you back up everything else.

**The `<name>-home` volume** — this holds live OAuth credentials for that
person's claude.ai and OpenAI accounts, plus their SSH private keys. Treat a
backup of it as you would treat their password.

```sh
# back up one user's home volume
docker run --rm \
  -v alice-home:/data:ro \
  -v "$PWD:/backup" \
  ubuntu:24.04 tar czf /backup/alice-home.tgz -C /data .

# restore into a fresh volume
docker volume create alice-home
docker run --rm \
  -v alice-home:/data \
  -v "$PWD:/backup" \
  ubuntu:24.04 tar xzf /backup/alice-home.tgz -C /data
```

All users at once:

```sh
mkdir -p /var/backups/agents
for name in $(python3 -c "import yaml;print(' '.join(u['name'] for u in yaml.safe_load(open('users.yaml'))['users']))"); do
  docker run --rm -v "${name}-home:/data:ro" -v /var/backups/agents:/backup \
    ubuntu:24.04 tar czf "/backup/${name}-home.tgz" -C /data .
done
```

Stop the container first if you want a consistent snapshot of a live SQLite
history file; for credentials alone a hot copy is fine.

Encrypt the results at rest, and keep `users.yaml` in version control — it holds
only public keys, so it is not sensitive, but it is what lets you rebuild the
whole host from scratch.

---

## Exposing sshd safely

Ports are published on `0.0.0.0:22NN`. That is convenient and it means **the
only thing between the internet and these containers is key-only SSH**. Put a
network boundary in front of it.

### The Docker/ufw trap, first

Docker inserts its own rules ahead of `ufw`'s INPUT chain. **A published port is
reachable even when `ufw` says the port is denied.** Filter in `DOCKER-USER`
instead, which Docker consults before its own forwarding rules:

```sh
# allow the tailnet, drop everything else, for the whole 22xx range
iptables -I DOCKER-USER -i tailscale0 -p tcp --dport 2201:2299 -j RETURN
iptables -I DOCKER-USER -i lo         -p tcp --dport 2201:2299 -j RETURN
iptables -A DOCKER-USER -p tcp --dport 2201:2299 -j DROP
```

Persist them (`iptables-persistent`, or your nftables ruleset) so they survive a
reboot. Verify from outside the tailnet that the port really is closed — do not
take the rule's existence as proof.

### Recommended: Tailscale

```sh
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --ssh=false --hostname=agent-host
```

Then users connect to the tailnet name and nothing is exposed publicly:

```sshconfig
Host agent-work
    HostName agent-host.your-tailnet.ts.net
    Port 2201
    User dev
```

With the `DOCKER-USER` rules above, that is the only route in.

### Alternative: bind to loopback and jump

If you would rather not run a VPN, change the one line in `portal`'s `render()`:

```python
"ports": [f"127.0.0.1:{port}:22"],
```

then `./portal update`. Users reach their container through the host:

```sshconfig
Host agent-work
    HostName    localhost
    Port        2201
    User        dev
    ProxyJump   you@your-server
```

The Codex desktop app follows `ProxyJump` fine.

### Either way

- Key-only auth, no passwords, no root login — enforced in `docker/sshd_config`.
- Only the `dev` account can log in (`AllowUsers dev`).
- Both key sources are mounted **read-only**, so nobody can add keys from inside
  their container. Note the flip side of the host file: whoever can edit
  `/home/alice/.ssh/authorized_keys` — Alice, and root — controls who reaches
  `work-alice`. That is the same trust boundary as her host account, which is
  the point, but it does mean a compromised host account is a compromised
  container. `extra_keys` is the half only you control.
- Revoking means removing the key from whichever source holds it (effective
  within ~15s), or `./portal rm alice`.
- Users have passwordless sudo **inside** their container. The container
  boundary is the security boundary; do not treat these as isolated from each
  other beyond what Docker gives you. Anyone with sudo in a container plus a
  kernel bug is on your host — keep the kernel patched and do not put people you
  do not trust on the same box.

---

## Host firewall and Docker's rules

Docker publishes ports and lets containers out through iptables rules of its own:
a `MASQUERADE` rule in the nat table plus the `DOCKER*` chains. **Anything that
flushes the ruleset removes them**, and Docker only puts them back when the
daemon starts. On Manjaro/Arch `systemctl restart iptables` does exactly this,
and so does a plain `iptables-restore` of a saved file, or any tool that
reloads the whole ruleset.

From that moment on, no container can reach the internet. Nothing crashes, so it
looks like an agent problem everywhere:

- `codex.log` goes `connecting`, then `Remote control is enabled … but the
  connection is errored`
- Codex's `app-server.stderr.log` repeats `failed to refresh available models:
  timeout waiting for child process to exit`
- phones show the container as last seen when the firewall was restarted

`./portal status <name>` names the cause directly under "network". To confirm
by hand:

```sh
docker exec work-alice curl -sS -m 10 -o /dev/null -w '%{http_code}\n' https://chatgpt.com/
curl -sS -m 10 -o /dev/null -w '%{http_code}\n' https://chatgpt.com/     # the host itself
sudo iptables -t nat -S POSTROUTING | grep -i masq                          # Docker's rule
```

If the host gets out, the container does not, and there is no `MASQUERADE` rule
for Docker's subnets, this is the cause.

**The fix is restarting the Docker daemon**, which recreates the rules. Do it
with `live-restore` on, so containers, and any long computation inside them,
keep running through the restart. Without it, a daemon restart stops every
container.

```sh
# /etc/docker/daemon.json: add "live-restore": true (mind the comma if the
# file already has entries). live-restore is one of the few settings a reload
# applies, so this needs no restart yet.
sudo jq . /etc/docker/daemon.json               # must parse
sudo systemctl reload docker
sudo journalctl -u docker -n 3 --no-pager       # "Error reloading configuration" = it did not take
docker info --format '{{.LiveRestoreEnabled}}'  # must be true before the next step

sudo systemctl restart docker
```

Two traps along the way:

- **systemd reports "Reloaded" even when dockerd rejected the file.** Only the
  journal and `docker info` tell the truth.
- **Never restart the daemon with a `daemon.json` that does not parse.** dockerd
  then does not start at all, and every container stays down.

Leave live-restore on; it makes every later Docker upgrade safe for running work
too.

**Stopgap without touching the daemon.** Re-add the missing rules by hand. The
next firewall restart removes them again, and the next Docker restart replaces
them properly.

```sh
sudo sysctl -n net.ipv4.ip_forward          # must be 1
for n in $(docker network ls --filter driver=bridge -q); do
  sub=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$n")
  br=$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$n")
  [ -n "$br" ] || br="br-$n"
  sudo iptables -t nat -A POSTROUTING -s "$sub" ! -o "$br" -j MASQUERADE
  sudo iptables -I FORWARD 1 -i "$br" ! -o "$br" -j ACCEPT
  sudo iptables -I FORWARD 1 -o "$br" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
done
```

The rule to remember: **on this host, every firewall restart must be followed
by a Docker restart.** Check the `DOCKER-USER` rules from "Exposing sshd safely"
afterwards as well. They come back only if they are in the saved ruleset the
firewall loads, and without them the containers' SSH ports are open to anyone
who can reach the host.

---

## Layout reference

| Path | What |
|---|---|
| `users.yaml` | source of truth (gitignored; keep it in your own private repo) |
| `compose.users.yml` | generated; never edit |
| `docker/Dockerfile.agent-base` | the shared image |
| `docker/toolchain.hook.sh` | **yours** — project toolchains |
| `docker/supervisor.sh` | sshd + both remote-control loops |
| `/opt/codex/packages/standalone` | Codex, in the image; every `~/.codex/packages/standalone` links here |
| `docker/sshd_config` | key-only sshd |
| `/srv/agents/<name>/projects` | bind-mounted to `~/projects` |
| `/home/<name>/.ssh/authorized_keys` | the host account's keys, mounted read-only |
| `/srv/agents/<name>/ssh/extra` | `extra_keys` rendered from users.yaml, read-only |
| volume `<name>-home` | `/home/dev` — credentials, config, host keys |

## Troubleshooting

`docker logs work-alice` prints a `remote control:` line at boot with the
resolved name, spawn mode, workdir and permission mode. That is the
authoritative view — `docker exec work-alice env` shows what the CONTAINER was
started with, which is not necessarily what the rc-loop is using, because the
loop runs under `su -l dev` and a login shell rebuilds the environment. The
supervisor bridges that gap through `/run/agent.env`.

**`docker logs work-alice`** is the supervisor's log: sshd lifecycle, host-key
generation, how many authorized keys it found, and a warning for any banned
environment variable it had to strip.

| Symptom | Look at |
|---|---|
| Nobody can SSH in | `docker logs work-alice` — it warns if neither source is mounted or no keys survive. `docker exec work-alice cat /etc/ssh/authorized_keys.d/dev` shows what sshd actually sees. |
| A new key on the host does not work | It syncs within ~15s **if the file was edited in place**. An editor that replaces the file gets a new inode, which the bind mount does not follow: `docker restart work-alice`. `ssh-copy-id` and `>>` append in place and are fine. |
| Session missing from claude.ai/code | `./portal status`; then `docker exec -it work-alice su -l dev -c 'tail -40 ~/rc.log'` |
| rc loop says "not signed in" | `./portal setup alice` |
| Session appears as `dev@<container-name>` | Pre-fix container: the AGENT_* vars were lost across `su -l`. Rebuild with `./portal update`. |
| `permission_mode` set but sessions still prompt | Check the `remote control:` line in `docker logs`, and the `starting:` line in `rc.log`, for `--permission-mode=`. Env vars alone do not prove it arrived. |
| `Worktree mode requires a git repository` in rc.log | `spawn: worktree` with a `workdir` that is not a repo. Set `spawn: same-dir`, or point `workdir` at a repo. Newer containers fall back automatically and say so. |
| Codex app cannot start app-server | `ssh -T -p 2201 dev@host 'command -v codex'` must print `/usr/local/bin/codex` |
| Every container went offline at the same moment; `codex.log` says `connecting`, then `connection is errored` | The containers cannot get out. See "Host firewall and Docker's rules": most likely the host firewall was restarted. `./portal status <name>` confirms it under "network". |
| `app server is running but is not managed by codex app-server daemon` in `codex.log` | The daemon lost its pid files while its app-server kept running (`DAEMON` reads `orphan`). Nothing restarts that app-server any more, so once its connection drops the phone loses the container. A current `supervisor.sh` stops the daemon's untracked processes and starts clean on its next poll, and logs `recovery:` when it does. On an older image, `./portal status <name>` prints the exact `kill` to run. An app-server the desktop app started over SSH is left alone either way. |
| Container missing from the Codex phone app | `./portal status <name>`, which checks the network, the daemon and its pid files together. `DAEMON` should be `up`. Then `docker exec -it work-alice su -l dev -c 'tail -40 ~/codex.log'`; it logs every state change of the daemon. `./portal pair alice` for a fresh code. |
| `managed standalone Codex install not found` | The image predates the standalone install, or `~/.codex/packages/standalone` is not linked. `./portal update`, then check `~/codex.log` for the `linked …` line. |
| `bwrap: No permissions to create a new namespace` in a session | Codex's sandbox cannot run inside these containers. See "Codex sandbox mode" — usually `sandbox_mode: danger-full-access`. |
| `sandbox_mode` set but sessions behave the same | Check the `starting:` line in `~/codex.log` for the `-c sandbox_mode=` argument. If it is right, the daemon predates it: `remote-control start` reports `alreadyRunning` and does not re-read config. `codex app-server daemon restart` in the container, or `./portal update`, which recreates it. |
| Codex version differs between containers | Somebody ran the upstream installer by hand inside one. `~/codex.log` says so. `rm -rf ~/.codex/packages/standalone` and restart to go back to the image's copy. |
| `codex login --device-auth` refused by the workspace | Use the SSH tunnel: `ssh -L 1455:localhost:1455 -p 22NN dev@host`, then `codex login` in that session. |
| Host key changed for everyone after an update | Should not happen — keys live in the home volume. If it did, the volume was recreated. |
| Container restart-looping | `docker logs work-alice`; a corrupt home volume is the usual cause. |

Never put `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`,
`ANTHROPIC_BASE_URL`, `DISABLE_TELEMETRY`, `DO_NOT_TRACK`,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_GROWTHBOOK`,
`CODEX_API_KEY`, `OPENAI_API_KEY` or `CODEX_HOME` in a compose file, the
Dockerfile, or a `settings.json`. Both remote controls need the account login —
Codex says so outright, "remote control requires ChatGPT authentication; API key
auth is not supported" — and any of these routes the CLI elsewhere. `CODEX_HOME`
is in the list for a different reason: moving it moves the standalone install
the container links into `~/.codex`, and the daemon stops finding it. `portal`
strips the credential ones from its own environment and `supervisor.sh` strips
all of them at container boot, but neither can help if they are baked into a
config file.
