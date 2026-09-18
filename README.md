# agent-host

A multi-user AI-agent host: one Docker container per person, each signed in with
**that person's own** Claude Code and/or Codex account.

- **Claude Code Remote Control** runs supervised inside each container, so the
  person's sessions show up in claude.ai/code and the Claude apps without any
  inbound port.
- **Codex** needs nothing but SSH: the desktop app spawns `codex app-server`
  itself on the far side.
- Logins, config and SSH keys live in a per-user named volume, so rebuilding the
  image never costs anybody a login.

```sh
./portal build                                        # build agent-base:latest
./portal add alice --key alice.pub --claude --codex   # container on port 2201
./portal setup alice                                  # one-time logins (needs Alice)
./portal status
```

| Doc | For |
|---|---|
| [docs/ADMIN.md](docs/ADMIN.md) | you: adding users, updating, backups, exposing sshd safely |
| [docs/USER-CLAUDE.md](docs/USER-CLAUDE.md) | hand to each Claude user |
| [docs/USER-CODEX.md](docs/USER-CODEX.md) | hand to each Codex user |

`users.yaml` is the source of truth; `compose.users.yml` and every
`authorized_keys` file are rendered from it. Run `./smoke-test.sh` on the server
to check a deployment end to end.
