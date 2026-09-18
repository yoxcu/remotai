# Codex on the agent host

Your container runs an SSH server. The **Codex desktop app** connects to it and
starts `codex app-server` on the far side itself — there is no extra daemon and
no extra port. You point the app at an SSH host alias and it does the rest.

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
# expect: /usr/bin/codex
```

If the first works and the second prints nothing, the app will fail with
something unhelpful like "could not start app server". Tell your admin — it is a
PATH problem on the server side, not something you can fix from here.

## 3. Add the host in the app

1. Open the Codex desktop app.
2. **Settings → Connections**.
3. **Add SSH host**.
4. Choose `agent-work` from the list (it reads your `~/.ssh/config`) or type the
   alias.
5. Connect.

The app opens the connection, launches `codex app-server` in your container, and
you are working against the server's filesystem — your repos are under
`~/projects`.

## 4. Working in the terminal instead

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

## 5. Troubleshooting

| Symptom | Cause |
|---|---|
| `Permission denied (publickey)` | Your key is not in the container's authorized_keys. Only your admin can add it — it is generated from `users.yaml` on the host and mounted read-only. |
| App says it cannot start the app server | Run the `ssh -T agent-work 'command -v codex'` check above. |
| Connection drops after idle | Check `ServerAliveInterval` is in your config. |
| `codex` says you are not logged in | The one-time `codex login` did not complete. Ask your admin to rerun `portal setup <you>`. |
| Host key changed warning | Only expected if your container's home volume was recreated. Confirm with your admin before removing the old key. |

## 6. Please don't

Don't add the container to shared automation or CI. Your container is signed in
with **your** account, and everything run in it is attributed to you.
