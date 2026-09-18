# Admin guide

One Docker image, one container per person, one `users.yaml`.

```
users.yaml  ──portal──▶  compose.users.yml           (containers)
                    └──▶  /srv/agents/<name>/ssh/dev  (authorized_keys)
```

`users.yaml` is the only file you edit. Everything else is rendered and is safe
to delete and regenerate. No container is given the Docker socket.

## Requirements

- Docker Engine with the Compose v2 plugin
- Python 3 with PyYAML (`apt-get install -y python3-yaml`)
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

```sh
./portal add alice --key ~/keys/alice.pub --claude --codex
```

`--key` takes a literal key, a path to a `.pub` file, or `-` for stdin, and may
be repeated. The port is auto-assigned from 2201 upward; pass `--port` to pin
one. This creates `/srv/agents/alice/{projects,ssh}`, renders everything, and
starts `work-alice`.

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
4. `codex login --device-auth` — another URL-and-code flow.
5. Restarting the container so the supervised loop takes over.

While setup runs, `portal` drops `/home/dev/.rc-paused` so the background loop
does not fight it for the same directory. It is removed afterwards even if you
Ctrl-C out.

Finally, send Alice `USER-CLAUDE.md` and `USER-CODEX.md` with her port filled
in.

### Checking on things

```sh
./portal status        # container state + both logins + the rc loop
./portal status -q     # skip the in-container probes (instant)
```

`NO LOGIN` under CLAUDE means the remote-control loop is idling and waiting —
rerun `portal setup`. The last line of each user's `~/rc.log` is printed below
the table.

---

## Updating

```sh
./portal update
```

Rebuilds `agent-base:latest` with a fresh `npm install -g` of
`@anthropic-ai/claude-code` and `@openai/codex`, then recreates every container.

**Nothing is lost.** Each `<name>-home` named volume is reattached to the new
container, so logins, `~/.claude`, `~/.codex`, `~/.ssh`, shell history and the
sshd host keys all survive. Users will not have to log in again and will not get
a host-key warning.

What *is* lost: anything a user `sudo apt install`ed at runtime. Durable tools
belong in `docker/toolchain.hook.sh`, which is rebuilt into the image. That hook
sits above the npm layer, so `portal update` re-pulls the agents without
re-running your toolchain, and editing the hook costs one npm install.

`--no-pull` rebuilds without forcing fresh agent packages, if you want to change
the image without moving versions.

Do this on a weekday morning, not mid-sprint: recreating a container interrupts
whatever sessions were running. They come back, but the work in flight does not.

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
- `authorized_keys` is rendered on the host and mounted **read-only**, so a user
  cannot grant access to their own container. Rotating a key means editing
  `users.yaml` and running `./portal render && ./portal update`.
- Users have passwordless sudo **inside** their container. The container
  boundary is the security boundary; do not treat these as isolated from each
  other beyond what Docker gives you. Anyone with sudo in a container plus a
  kernel bug is on your host — keep the kernel patched and do not put people you
  do not trust on the same box.

---

## Layout reference

| Path | What |
|---|---|
| `users.yaml` | source of truth (gitignored; keep it in your own private repo) |
| `compose.users.yml` | generated; never edit |
| `docker/Dockerfile.agent-base` | the shared image |
| `docker/toolchain.hook.sh` | **yours** — project toolchains |
| `docker/supervisor.sh` | sshd + the remote-control loop |
| `docker/sshd_config` | key-only sshd |
| `/srv/agents/<name>/projects` | bind-mounted to `~/projects` |
| `/srv/agents/<name>/ssh/dev` | generated authorized_keys, mounted read-only |
| volume `<name>-home` | `/home/dev` — credentials, config, host keys |

## Troubleshooting

**`docker logs work-alice`** is the supervisor's log: sshd lifecycle, host-key
generation, how many authorized keys it found, and a warning for any banned
environment variable it had to strip.

| Symptom | Look at |
|---|---|
| Nobody can SSH in | `docker logs work-alice` — it warns if authorized_keys is missing or empty. Then `./portal render`. |
| Session missing from claude.ai/code | `./portal status`; then `docker exec -it work-alice su -l dev -c 'tail -40 ~/rc.log'` |
| rc loop says "not signed in" | `./portal setup alice` |
| Codex app cannot start app-server | `ssh -T -p 2201 dev@host 'command -v codex'` must print `/usr/bin/codex` |
| Host key changed for everyone after an update | Should not happen — keys live in the home volume. If it did, the volume was recreated. |
| Container restart-looping | `docker logs work-alice`; a corrupt home volume is the usual cause. |

Never put `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`,
`ANTHROPIC_BASE_URL`, `DISABLE_TELEMETRY`, `DO_NOT_TRACK`,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` or `DISABLE_GROWTHBOOK` in a compose
file, the Dockerfile, or a `settings.json`. Remote Control needs the claude.ai
account login; any of these routes Claude Code elsewhere and sessions stop
appearing. `portal` strips them from its own environment and `supervisor.sh`
strips them at container boot, but neither can help if they are baked into a
config file.
