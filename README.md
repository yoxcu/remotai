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
./portal add alice --claude --codex                   # container on port 2201
./portal setup alice                                  # one-time logins (needs Alice)
./portal status
```

| Doc | For |
|---|---|
| [docs/ADMIN.md](docs/ADMIN.md) | you: adding users, updating, backups, exposing sshd safely |
| [docs/USER-CLAUDE.md](docs/USER-CLAUDE.md) | hand to each Claude user |
| [docs/USER-CODEX.md](docs/USER-CODEX.md) | hand to each Codex user |

`users.yaml` says who has a container and `compose.users.yml` is rendered from
it. SSH keys are not copied anywhere: each container reads that person's own
`~/.ssh/authorized_keys` from their host account, mounted read-only, so
rotating a key on the host rotates it in the container. Run `./smoke-test.sh` on the server
to check a deployment end to end.
