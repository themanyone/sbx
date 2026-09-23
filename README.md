# sbx — ephemeral bubblewrap sandbox for coding agents

Caps the filesystem blast radius of coding agents using [Bubblewrap](https://github.com/containers/bubblewrap), the same unprivileged sandbox used by [Flatpak](https://flatpak.org/) and friends. An agent runs inside
a [user namespace](https://www.google.com/search?q=user+namespaces+site%3Ahttps%3A%2F%2Flwn.net)  with only a project directory, agent configuration, and a
read-only copy of the host development toolchain. It provides quick & dirty
protection against accidental access/modification/deletion. The maintainers
believe it won't allow privilege escalation when properly configured, and
without specialized hacker tools.

Nevertheless, it is not a security boundary against hostile code. A determined
agent, or even an unprivileged user can get around it with enough effort.
See `SECURITY.md` for the threat model, what does and does not sync, and
secret handling.

## Layout

```
bin/sbx                              the wrapper
etc/sbx.conf                         sandbox specification (mount plan)
etc/sbx-crush.conf                   variant spec that also exposes Crush config
docs/superpowers/specs/              design document
tests/verify.sh                      attempted-violation test suite
SECURITY.md                          threat model, limits, secret handling
```

## Install

```
install -Dm755 bin/sbx ~/.local/bin/sbx
install -Dm644 etc/sbx.conf ~/.config/sbx/sbx.conf
install -Dm644 etc/sbx-crush.conf ~/.config/sbx/sbx-crush.conf
```

The third line is the variant spec used to run an agent with its own config
(see below). Install it even if you only intend to use the default spec:
`SBX_CONF` names a file that must exist, and pointing it at a path that is not
there fails every invocation with `config not found`. Installing it does not
weaken the default, which stays in force until you opt in explicitly.

## Use

```
sbx run ~/project-dir -- crush              run a command with that dir writable
sbx run --agent ~/project-dir -- crush      same, plus the agent's own config
sbx shell ~/project-dir                     interactive shell
sbx check ~/project-dir                     print the resolved bwrap command, run nothing
sbx check --shell ~/project-dir             print what `shell` would run instead
```

`sbx check` is how you verify the boundary rather than assume it. It shows the
`run` plan by default; `--shell` shows the interactive plan, which differs by
dropping `--new-session` so the shell keeps job control. The sandboxed command
stays detached from your terminal either way, which is what stops it injecting
keystrokes into your shell.

The spec keys are documented in `etc/sbx.conf`. Two rules are worth knowing when
editing a spec: an unknown key is a hard error, and the four toggle keys
(`unshare_pid`, `unshare_ipc`, `unshare_uts`, `network`) accept only `on` or
`off`. A typo in either case exits 2 with a line number rather than silently
leaving the sandbox weaker than intended.

### Launching an agent with its config and skills

By default the sandbox hides `~/.config/crush`, so Crush cannot authenticate and
sees no skills. Add `--agent` to mount its config and skills and give it a
writable session copy of its data directory:

```
sbx run --agent ~/project-dir -- crush
```

`--agent` must appear before the `--` separator, so a command that takes its own
`--agent` argument still receives one. It applies to `run`, `shell`, and `check`.

What it mounts:

| Host path | Mode | Why |
| --- | --- | --- |
| `~/.config/crush/crush.json` | read-only | Crush reads it, never writes it |
| `~/.config/crush/skills/` | read-only | prompts and scripts; a directory mount is needed or every skill stays hidden |
| `~/.local/share/crush/` | **writable copy** | Crush rewrites this while running |

Crush writes its data directory on every run (model selection, session state,
and the locks it takes), so a read-only mount fails with `device or resource
busy`. `--agent` copies the directory into a session temp dir, binds that
writable, and points `XDG_DATA_HOME` at it. The copy is discarded on exit and
your real data dir is never modified. That is also why no environment variables
are needed: the provider keys come from the mounted copy, not from your shell.

`--agent` exposes live API credentials to everything the sandboxed command runs,
including any tool or skill script the agent invokes. Pass it for agent sessions
you trust; for untrusted code, use the default spec instead. The exposure is
bounded: the config and skills are read-only (`EROFS` on write), the writable
data dir is a temp copy, and your host files are untouched either way.
`tests/verify.sh` checks all three.

```
sbx run --agent ~/project-dir -- crush    # config, skills, writable data dir
sbx run ~/project-dir -- crush            # no credentials, no auth
SBX_CONF=<your-own-spec> sbx run ~/project-dir -- crush   # your own mount plan
```

## Verify

```
tests/verify.sh
```

Exits nonzero if any check failed, after printing a full pass/fail tally.
Checks 14-16 need `SBX_CRUSH_CONF` set (defaults to `etc/sbx-crush.conf`).

## Design

Type: shell script (look it over).
Task: Invokes bubblewrap with flags from sbx.conf

## Security

Read `SECURITY.md` before trusting the boundary. The short version: the sandbox
runs as your own UID, so it is not a privilege boundary and not containment for
hostile code. It exists to stop an agent acting on misread instructions from
reaching host paths outside the project. `--agent` exposes live API credentials
by design. Use `sbx check <dir>` to verify the mount plan rather than assume it.

## Docker as an alternative

See `SECURITY.md` for the full comparison. Briefly:

- **Docker/Podman pros:** a real UID/seccomp boundary, a pinned reproducible
  image, and easy egress control. Better when you need genuine containment or a
  versioned toolchain.
- **Docker/Podman cons:** a useful image is 2-6GB and starts in 1-3s per command
  instead of ~200ms; `-v` grants the project with the same semantics as
  `--bind`; and a root daemon's socket is equivalent to host root, a larger trust
  surface than `bwrap`.
- **User Mode Linux:** a real guest kernel with no root or KVM, useful for
  containment where a dedicated user and rootless Podman are not options. Costs
  syscall-trap latency on IO-heavy work and makes you patch a guest kernel. Prefer
  gVisor for the same niche.

Stay with `sbx` for capping accidental access on your own machine.

## Credits

AI-generated and carefully looked-over by Henry Kroll III, www.thenerdshow.com
16 September 2026. Blame him if it doesn't work or point your agent at it.

Prompt: "brainstorm setting up a lightweight container or chroot on Linux to limit access to agents"

Software comes with NO WARRANTEES. Not even the implied warrantee
of merchantability for a particular purpose.

License: Public Domain

Support more projects, bug fixes & maintenaince:

- GitHub https://github.com/themanyone
- YouTube https://www.youtube.com/themanyone
- Mastodon https://mastodon.social/@themanyone
- Linkedin https://www.linkedin.com/in/henry-kroll-iii-93860426/
- Buy me a coffee https://buymeacoffee.com/isreality
- [TheNerdShow.com](http://thenerdshow.com/)
