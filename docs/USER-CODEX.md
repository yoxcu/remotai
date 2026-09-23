# Codex on the agent host

Your container gets you Codex two ways, off one login:

- **Desktop app** — it connects over SSH and starts `codex app-server` on the
  far side itself. No extra daemon, no extra port. Sections 1–4.
- **Phone app** — a supervised `codex remote-control` daemon runs in the
  container and registers it with your ChatGPT account, so the container shows
  up in Codex on your phone. Nothing is exposed inbound; the daemon dials out.
  Section 5.

Your admin runs `portal setup <you>` with you once to sign Codex in inside the
container. After that this is a two-minute setup on your own machine.

---

## 1. Add an SSH host alias

The desktop app connects to a **named `Host` entry** from your `~/.ssh/config`,
not to a free-form `user@host:port`. So the alias has to exist first.

Add this to `~/.ssh/config` on your laptop (create the file if needed, it should
be mode `600`), filling in your port and server:

```sshconfig
Host agent-work
    HostName          your-server.example.com
    Port              2201
    User              dev
    IdentityFile      ~/.ssh/id_ed25519
    IdentitiesOnly    yes
    # Keeps the long-lived app-server connection alive through NAT and sleep.
    ServerAliveInterval 30
    ServerAliveCountMax 6
```

`Host agent-work` is the name you will pick in the app — call it whatever you
like.

## 2. Check it works, twice

First, a normal login:

```sh
ssh agent-work
```

Then the check that actually matters. The app does **not** open an interactive
shell — it runs a single command over SSH. Verify that `codex` is findable that
way:

```sh
ssh -T agent-work 'command -v codex'
# expect: /usr/local/bin/codex
```

If the first works and the second prints nothing, the app will fail with
something unhelpful like "could not start app server". Tell your admin — it is a
PATH problem on the server side, not something you can fix from here.

## 3. Signing Codex in (one time)

Your admin normally does this with you via `portal setup`. If you are doing it
yourself, note that `codex login` serves an OAuth callback on `localhost:1455`
and expects a browser on the same machine — neither is true inside a container.

**Forward the port into the container over SSH.** The tunnel has to end up
*inside* the container, which is why this uses your container's port and not a
shell on the server:

```sh
ssh -L 1455:localhost:1455 -p 2201 dev@your-server
```

Then, in that same SSH session:

```sh
codex login
```

It prints a URL. Open it in your own browser. The redirect back to
`localhost:1455` travels down the tunnel into the container, and your login is
written to `~/.codex` — on the persistent volume, so it survives image updates.

`codex login --device-auth` avoids the tunnel entirely, but many ChatGPT
workspaces disable it ("contact your workspace admin to enable device code
authentication"). If yours does, use the tunnel.

Check it worked:

```sh
codex login status
```

## 4. Add the host in the app

1. Open the Codex desktop app.
2. **Settings → Connections**.
3. **Add SSH host**.
4. Choose `agent-work` from the list (it reads your `~/.ssh/config`) or type the
   alias.
5. Connect.

The app opens the connection, launches `codex app-server` in your container, and
you are working against the server's filesystem — your repos are under
`~/projects`.

## 5. Your phone

The container runs `codex remote-control` under supervision, so once it is
signed in it registers itself with your ChatGPT account and stays registered
across restarts. There is nothing to install and nothing to leave running on
your laptop.

1. Install Codex on your phone and sign in with the **same ChatGPT account**
   the container is signed in as.
2. Look for this machine in the app's list of computers. It appears under your
   container's name — `alice`, not `alice@server`: Codex names the device after
   the container's hostname, and unlike Claude there is no flag to change that.
3. If it is not listed, ask your admin for a pairing code:

   ```sh
   ./portal pair alice        # on the server
   ```

   That prints a short-lived code; type it into the app. Expired codes are not
   a problem — they can print another.

Sessions you start from the phone run in your container against your repos
under `~/projects`, the same files the desktop app and a plain SSH session see.

Two things worth knowing:

- Remote control needs the **ChatGPT account** login. An API key will not do —
  Codex refuses outright. That is the same login as section 3, so if the desktop
  app works, this will too.
- Restarting the container (a `portal update`, say) interrupts running sessions.
  The pairing survives; the work in flight does not.
- Your admin may have set a **sandbox mode** for these sessions. If commands
  come back with `bwrap: No permissions to create a new namespace`, that is not
  something you can fix from the phone — tell them; it is a one-line change on
  their side.

## 6. Working in the terminal instead

Nothing stops you from using Codex over plain SSH:

```sh
ssh agent-work
cd ~/projects/my-repo
codex
```

Use tmux if you want it to survive a dropped connection:

```sh
tmux new -s work     # later: tmux attach -t work
```

Note that `rc` is a reserved session name — that is the Claude Remote Control
loop, if you have Claude enabled too. Leave it alone.

## 7. Troubleshooting

| Symptom | Cause |
|---|---|
| `Permission denied (publickey)` | Your container reads your **own** `~/.ssh/authorized_keys` on the server. Add the key there (`ssh-copy-id`, or append to the file) and it works within ~15s — no admin needed. If you have no account on the server, your admin adds the key to `extra_keys` instead. |
| App says it cannot start the app server | Run the `ssh -T agent-work 'command -v codex'` check above. |
| Connection drops after idle | Check `ServerAliveInterval` is in your config. |
| `codex` says you are not logged in | The one-time `codex login` did not complete — see section 3. |
| `Please contact your workspace admin to enable device code authentication` | Your ChatGPT workspace blocks `--device-auth`. Use the SSH tunnel in section 3 instead. |
| The container never shows up on your phone | Check you are signed into the same ChatGPT account in both places, then ask your admin for a pairing code (`./portal pair <you>`). They can also check `~/codex.log` in your container, which records every state change of the daemon. |
| It showed up, then went quiet | Usually the container restarted. Give it a minute; the daemon is supervised and comes back on its own. If it stays quiet, ask your admin to run `./portal status <you>`: it checks whether your container can reach the internet at all, which is the other common cause. |
| Host key changed warning | Only expected if your container's home volume was recreated. Confirm with your admin before removing the old key. |

## 8. Please don't

Don't add the container to shared automation or CI. Your container is signed in
with **your** account, and everything run in it is attributed to you.
