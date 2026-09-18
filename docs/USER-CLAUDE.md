# Claude Code on the agent host

You have your own container on the server. It is signed in with **your**
claude.ai account and nobody else's, and it keeps a Claude Code Remote Control
server running around the clock in `~/projects`.

Your admin runs `portal setup <you>` with you once. After that there is nothing
to start — the container restarts the server by itself.

---

## 1. Where your sessions show up

Once the server is running, the same session appears in all of these:

| Where | How |
|---|---|
| **claude.ai/code** | Open it in a browser. Your container is listed by name, as `<you>@<server>`. |
| **Claude desktop app** | Same list, under Code. |
| **Claude mobile app** | Same list. Handy for kicking something off and checking back. |

Pick it and start a session. Each new session gets its **own git worktree**, so
two of your sessions never fight over the same working tree. Your repos live in
`~/projects` inside the container.

If the entry is missing, it is nearly always one of:

- the container is restarting (give it ~15 s),
- the server has been offline long enough to drop off — it comes back by itself
  within about a minute,
- your admin needs to rerun `portal setup`.

## 2. Getting to it from a terminal

You also have plain SSH access. Ask your admin for your port (`22NN`):

```sh
ssh -p 2201 dev@your-server
```

The live Remote Control server runs inside a tmux session called `rc`:

```sh
# attach in one go
ssh -p 2201 dev@your-server -t 'tmux attach -t rc'

# or once you are already logged in
tmux attach -t rc
```

**Detach with `Ctrl-b` then `d`.** Do not `Ctrl-C` in that pane — that kills the
server. It restarts within five seconds, but any session it was hosting is
interrupted.

To see the sessions it has spawned, from anywhere inside the container:

```sh
claude agents          # list background sessions
claude attach <id>     # open one in your terminal
claude logs <id>       # print its recent output
```

And you can always just run Claude Code normally:

```sh
cd ~/projects/my-repo && claude
```

## 3. What persists, and what does not

Everything under `/home/dev` is on a named Docker volume that survives restarts
and image updates:

- `~/.claude` — your login, settings, history
- `~/.codex` — likewise, if you use Codex too
- `~/.ssh` — your keys for pushing to GitHub etc.
- `~/.bashrc`, shell history, `~/.local/bin`, `~/.npm-global`

`~/projects` is a bind mount from the server's disk — also permanent, and what
your admin backs up.

**Not** permanent: anything you `sudo apt install` at runtime. You do have
passwordless sudo, but the container is rebuilt from a fresh image on every
`portal update` and those packages go away. For a tool you want to keep:

- ask your admin to add it to `docker/toolchain.hook.sh`, or
- install it into your home volume instead — `pip install --user`, or
  `npm install -g` after `npm config set prefix ~/.npm-global` (already on your
  PATH).

## 4. Adding a machine

Your container accepts exactly the keys in your **own**
`~/.ssh/authorized_keys` on the server — the same file you already use to log
into the host. Working from a new laptop:

```sh
ssh-copy-id -p 22 you@your-server     # your normal host login
```

The container picks the new key up within about 15 seconds. You do not need
your admin, and you cannot edit the key list from inside the container (it is
mounted read-only there, on purpose).

If you use an editor that *replaces* the file rather than appending to it, ask
your admin to `docker restart` your container — the mount follows the original
file.

## 5. Housekeeping

`~/rc.log` is the server's own log — start/stop times, exit codes, and anything
it wrote to stderr:

```sh
tail -f ~/rc.log
```

If the server looks wedged, killing it is safe; the supervisor brings it back
in five seconds with your sessions intact (it restores them for about four
hours after a restart):

```sh
tmux attach -t rc     # Ctrl-C, then watch it come back
```

## 6. Please don't

Do not set `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_BASE_URL` in your `~/.bashrc` or
`~/.claude/settings.json`. Remote Control only works with a claude.ai account
login, and any of those variables silently sends Claude Code down a different
auth path — your sessions will simply stop appearing. The container strips them
at boot and warns in the logs, but it cannot strip what your shell sets later.
