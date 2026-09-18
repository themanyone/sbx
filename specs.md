# Design: Ephemeral bubblewrap Sandbox for Coding Agents

Date: 2026-09-16
Host: Fedora 43 (lxqt), amd64, 16 CPUs
Status: awaiting user approval

## Problem

Coding agents run with the full authority of the invoking user. On this host that
means an agent working in `~/Downloads` can read `~/.ssh`, browser profiles,
`~/.config`, `~/.gnupg`, and every other project directory, and can delete the
large training artifacts that live alongside the working files.

The goal is to cap the blast radius of filesystem access for agent processes,
without changing how agents are normally launched and without giving up network
access (npm/pip installs must still work).

## Scope

In scope:

- A wrapper that runs any command, most often an agent CLI, inside a filesystem
  view containing only the project directory and a read-only copy of the host
  toolchain.
- Ephemeral state: nothing written outside the project directory survives the
  command's exit.
- No access to credential directories, Unix sockets, D-Bus, X11/Wayland, or
  systemd user services.

Out of scope:

- Network restriction. The network namespace is left intact.
- Supply-chain isolation. Package downloads are not gated or filtered.
- Privilege escalation. This is not a privilege boundary; the sandbox runs as the
  invoking user and is not intended to contain hostile code, only to constrain an
  agent acting on misread instructions or over-eager tool use.
- Windows, macOS, and non-Fedora hosts.
- Changes to Crush's own `crush.json` permission system.

## Non-goals

The sandbox is not a security boundary against a determined local attacker. An
agent that can write to the project directory can still place files there. The
property being enforced is that *host paths outside the project are unreachable*,
not that everything inside the project is safe.

## Decisions

Chosen approach: a single bubblewrap wrapper script. Rationale recorded below.

| Decision | Choice | Rationale |
| --- | --- | --- |
| Mechanism | `bwrap` | Present at `0.12.0`; no daemon; ~200ms startup, which matters when an agent issues hundreds of short shell calls |
| Lifetime | Ephemeral per invocation | Installed packages, dotfiles, and temp files are discarded; nothing to clean up |
| Host toolchain | Bind read-only | The real Fedora `python`/`node`/`gcc` remain visible, so no multi-GB image is needed |
| Network | Left intact | Installs must work; filesystem was the identified threat |
| Sockets | Not mounted | `/run/user/$UID` is absent, so ssh-agent, gpg-agent, and D-Bus are unreachable |
| Crush integration | None | The wrapper is the boundary; Crush config is unchanged |

Rejected alternatives:

- **Podman rootless `--rm` per run.** Stronger isolation, but a useful image needs
  python/node/gcc/torch baked in (2-6GB) or read-only host binds that reintroduce
  the same fragility, and 1-3s startup per command is costly for agent workloads.
  Note: Docker Hub anonymous pulls fail on this host (`unauthorized`); only
  `quay.io` and `registry.fedoraproject.org` are usable, so images would need a
  Fedora base regardless.
- **Named profiles for per-language mount sets.** Deferred. Adds configuration
  surface for a need that has not appeared. It is a small additive change to the
  config format below if it becomes necessary.

## Architecture

Two files.

```
~/.config/sbx/sbx.conf    sandbox specification: what gets mounted
~/.local/bin/sbx          wrapper: parses args, runs bwrap
```

The wrapper reads the spec and constructs one `bwrap` invocation. There is no
daemon, no state database, and no registry of sandboxes.

### Mount plan

Read-only, from host:

- `/usr` — binaries, libraries, and the Python/Node toolchains
- `/etc` — passwd, group, resolv.conf, TLS trust store, fonts
- `/etc/ssl`, `/etc/pki` are already covered by `/etc`
- `/opt` — only if it exists; some toolchains install there

Writable, project scope:

- The one project directory named on the command line, bound at the same absolute
  path so agent output and error messages reference real locations

Writable, discarded on exit:

- `/tmp` — tmpfs
- `/var/tmp`, `/var/cache`, `/var/log` — tmpfs, so package managers work
- The sandbox `$HOME` — tmpfs, so dotfiles are written to a scratch area and the
  host home is never touched
- `/run` — tmpfs, deliberately not the host `/run/user/$UID`

Deliberately absent:

- The real `~` tree, except the one bound project directory
- `/run/user/$UID` — removes ssh-agent, gpg-agent, and the D-Bus session socket
- `/tmp/.X11-unix`, `$XDG_RUNTIME_DIR/wayland-*` — no display access
- `/dev/dri`, `/dev/snd` — no GPU or audio devices
- Any block device, `/boot`, `/root`

### Namespace flags

- `--unshare-pid` — agent cannot signal or inspect host processes
- `--unshare-ipc` — no shared memory with host processes
- `--unshare-uts` — scrubbed hostname
- `--unshare-cgroup-try` — no cgroup view
- `--die-with-parent` — no orphaned sandbox if the wrapper is killed
- `--new-session` — detaches from the controlling terminal, so an agent cannot
  inject keystrokes into the parent shell. Applied to `run` but deliberately
  **not** to `shell`: detachment and job control are mutually exclusive, and an
  interactive shell without job control prints `cannot set terminal process
  group` and `no job control in this shell` at every startup. `cmd_shell` sets
  `INTERACTIVE=1` to suppress it. The two plans are distinct, which is why
  `sbx check --shell <dir>` exists alongside `sbx check <dir>`.
- Network namespace intentionally *not* unshared

### Config format

`sbx.conf` is a flat key/value file, parsed by the wrapper with no external
dependencies. Keys:

```
# Read-only host paths, space separated, available in order
ro_bind = /usr /etc /opt

# Extra writable binds beyond the project directory; empty by default
rw_bind =

# Read-only single files; repeatable. Parent dirs are created empty so a file
# can be mounted without exposing its siblings.
ro_file =

# Read-only directory trees; repeatable. Unlike ro_file this exposes the whole
# subtree, so it is for content that is already safe to hand to the sandbox.
# A ro_file inside a directory leaves that directory empty, so a tree whose
# contents must be visible in full needs ro_dir.
ro_dir =

# Absolute paths to hide even if reachable via a parent bind
hide = /usr/lib/debug

# Extra sandbox environment variables
env = TERM=xterm-256color

# Namespace toggles, on by default
unshare_pid = on
unshare_ipc = on
unshare_uts = on
network = on
```

Repeatable keys (`rw_bind`, `ro_file`, `ro_dir`, `hide`, `env`) append across
lines; a single line may also list several space-separated values. An empty
value is legal and means "no entries".

Unknown keys are a hard error, so a typo cannot silently weaken the sandbox.
The four toggle keys accept only `on` or `off` (case-insensitively) for the
same reason: any other value exits 2 rather than being compared loosely and
failing open.

A config value is not subject to shell expansion. The wrapper expands a leading
`~` or `~/` to `$HOME` itself, because neither `read` nor `bwrap` does so, and
an unexpanded `ro_file = ~/...` would be silently skipped as absent.

### Mount ordering

Order is load-bearing. Three of these were real observed failures during
implementation, not hypotheticals:

1. Read-only base binds from `ro_bind`.
2. usrmerge symlinks for `/bin`, `/sbin`, `/lib`, `/lib64`.
3. `--tmpfs $HOME`, which erases the host home tree.
4. `ro_file` binds, which must come *after* step 3 or the empty parent
   directories created for them are wiped by it. `ro_dir` is emitted here too
   for the same reason.
5. Writable tmpfs for `/tmp`, `/var/tmp`, `/var/cache`, `/var/log`, `/run`.
6. `hide` tmpfs overlays.
7. The DNS directory and resolver bind, which must come *after* step 5 because
   `/run` is a tmpfs and would otherwise erase it.
8. The project bind, last, so it lands on top of the scrubbed home.
9. Namespace flags, then `--`.

`ro_bind` is emitted *before* step 3, so a `ro_bind` entry under the home
directory is erased by the `$HOME` tmpfs. Paths under `~` must use `ro_file`
(one file, siblings hidden) or `ro_dir` (whole tree).

### DNS

The host `/etc/resolv.conf` points at `systemd-resolved`'s stub on `127.0.0.53`,
which listens on host loopback and is therefore unreachable inside the sandbox.
Without a fix, every network operation fails with `connection refused` on
`127.0.0.53:53`.

The wrapper copies `/run/systemd/resolve/resolv.conf` (the non-stub file listing
real upstream servers) to a temporary file, then recreates
`/run/systemd/resolve/` inside the sandbox and binds that file over
`stub-resolv.conf`. `/etc/resolv.conf` is a symlink into `/run`, so binding over
the symlink directly fails with `Can't mount on symlink destination`; the final
path must be used instead.

### Giving an agent its own config

Crush keeps its provider list, model selection, and API credentials in
`~/.config/crush/crush.json` and `~/.local/share/crush/{crush,providers,hyper}.json`.
Its skills live in `~/.config/crush/skills/`, one directory per skill. All of it
is hidden by default, so Crush inside the sandbox can neither authenticate nor
see any skill.

The `--agent` flag adds those four files via `ro_file` and the skills tree via
`ro_dir`. The skills need `ro_dir` rather than `ro_file`: a `ro_file` mount
creates its parent directory empty, so a `ro_file` pointing at one SKILL.md
would hide every other skill. Only the named files and trees become reachable;
the parent directories otherwise appear empty, which is verified by tests 14-16.

`--agent` hands over live credentials, which is the point of the flag: Crush
keeps its provider keys as literal values in `crush.json` and cannot reach a
provider without them. Passing `--agent` is therefore the acknowledgement, and
there is no separate opt-in variable.

An earlier revision refused to run when the mounted config held a literal key.
That was removed because it fired on every launch, since literal keys are the
normal case, and made the flag unusable for its intended purpose. The bounds
that matter are structural rather than procedural: the config dir and skills are
read-only, and the writable data dir is a discarded temp copy, so the host is
not modified.

`etc/sbx-crush.conf` remains as a hand-editable example of the config-and-skills
half of the mount set, for anyone who wants to adjust it without touching the
wrapper. It is not read by `--agent`, because a spec file cannot express the
writable data-dir copy below.

### The writable data dir

Crush's data directory is not read-only input. It rewrites `crush.json` and
`projects.json` and takes lock files while running, so mounting the host
directory read-only fails with `device or resource busy` on the first write, and
mounting it writable would let a sandboxed agent edit the host's real model
selection and credentials.

`--agent` therefore copies the tree to a session temp dir, binds that writable,
and sets `XDG_DATA_HOME` to it. The copy keeps a `crush/` level because
`XDG_DATA_HOME` names the parent of `crush/`. Lock files are dropped, since they
name host PIDs and the sandbox has its own pid namespace, so a stale lock can
look held forever. The copy is removed on exit; a sweep at startup removes
copies left by a process that was `SIGKILL`ed, since those hold live keys.

No environment variables are involved. The provider keys reach Crush through the
mounted copy of its own config, which is why an agent session needs no exported
credentials and nothing secret appears in the wrapper.

The config dir and the skills tree stay read-only. A write to them fails with
`EROFS` inside the sandbox and leaves the host untouched.


### Invocation

```
sbx run [--agent] <dir> -- <command> [args...]   run a command with <dir> writable
sbx shell [--agent] <dir>                        interactive shell with <dir> writable
sbx check [--agent] <dir>                        print the resolved bwrap command and exit
sbx check [--agent] --shell <dir>                print what `shell` would exec instead
```

`sbx check` is the important one: it makes the mount plan inspectable without
executing anything, so the boundary can be verified rather than assumed. It
describes the `run` plan by default; pass `--shell` for the interactive plan,
which differs by omitting `--new-session`.

`--agent` adds the agent profile described above. It must appear before the `--`
separator so that a command taking its own `--agent` argument still receives
one.

Examples:

```
sbx run ~/Downloads/src -- crush                 no credentials, no auth
sbx run --agent ~/Downloads/src -- crush         config, skills, writable data copy
```

## Data flow

1. Wrapper parses `sbx.conf`, aborting on unknown keys or missing paths.
2. Wrapper resolves the project directory to an absolute path and confirms it
   exists; a nonexistent directory is an error, not a silent empty bind.
3. Wrapper builds the `bwrap` argv in the order: base binds, tmpfs overlays,
   `hide` exclusions, project bind, namespace flags, then the command.
4. `bwrap` sets up namespaces, drops into the mount view, and execs the command.
5. On exit, all tmpfs content is released by the kernel. Nothing to clean up.

Ordering matters: tmpfs overlays are applied after the `~` handling and
before the project bind, so the project remains writable even though its parent
tree is not present.

## Error handling

| Condition | Behaviour |
| --- | --- |
| `bwrap` not found | Exit 2 with an install hint; do not fall back to running unsandboxed |
| Unknown key in `sbx.conf` | Exit 2, name the offending key |
| Toggle key with a value other than `on`/`off` | Exit 2, name the key and value; a typo must not fail open |
| `--agent` after the `--` separator | Passed through to the command, not treated as a sandbox flag |
| Line in `sbx.conf` without `=` | Exit 2, name the file and line number |
| Config file missing | Exit 2, name the path |
| Missing `ro_bind` path | Skip with a warning on stderr; `/opt` is commonly absent |
| Missing `ro_file`/`ro_dir` path | Skip with a warning on stderr |
| Project dir missing or not a directory | Exit 2, name the path |
| Project dir is a symlink | Resolve with `realpath` first, then bind the target |
| No command given to `run` | Exit 2 |
| Unknown subcommand | Print usage, exit 2 |
| Sandbox command exits nonzero | Propagate the exit code unchanged |
| Wrapper killed mid-run | `--die-with-parent` tears the sandbox down |
| Command attempts host write outside project | Fails with EROFS or ENOENT inside the sandbox; host is unaffected |
| Command writes to a read-only `ro_bind`/`ro_file`/`ro_dir` path | Fails with EROFS inside the sandbox; host is unaffected |

Exit 2 is the single failure status for every condition the wrapper detects,
produced by `die`. The wrapper never uses exit 127 or any other
command-not-found convention: a sandbox construction failure must be
distinguishable from the exit code of the command that would have run inside.

There is no fallback path that runs the command unsandboxed. A failure to
construct the sandbox is always a hard failure.

## Testing

Verification is by attempted violation, run as a script against a scratch
project directory containing a canary file.

Must pass:

1. `cat ~/.ssh/id_ed25519` → ENOENT
2. `ls ~/.config` → ENOENT
3. `ls ~/Downloads` → fails, since only the bound project is visible
4. `cat $PROJECT/canary` → succeeds, proving the bind works
5. `echo x > $PROJECT/newfile` → succeeds, and the file is present on the host
   after exit, proving writes propagate to the project
6. `touch ~/.sandbox_escape` → appears to succeed inside the sandbox because
   `$HOME` is tmpfs, but leaves nothing on the host
7. `touch /usr/local/bin/escape` → fails, `/usr` is read-only
8. `echo x > /tmp/scratch_probe` → succeeds inside, absent on host after exit,
   proving ephemerality
9. `test -e /run/user/$UID` → fails
10. `ls /proc` → only sandbox processes visible
11. `sbx check` output contains no `~/.ssh`, `~/.gnupg`, `~/Downloads`
12. Exit code of a failing command is preserved
13. Harness sanity: a known project-side effect from check 5 is still present,
    proving the earlier checks ran against a working sandbox rather than a
    silent no-op
14-16. `ro_file`/`ro_dir` contract, skipped unless `SBX_CRUSH_CONF` names an
    existing file: the named file is readable, its parent directory still lists
    only bound entries, and a `ro_dir` tree is visible in full.
17-19. Without `--agent` the agent config stays hidden; with it the config and
    the skills tree both appear.
20. `--agent` runs unattended, with no environment prefix, even though the
    mounted config holds literal API keys.
21. The writable data-dir copy is removed when the command exits.
23-24. `run` keeps `--new-session`; `shell` omits it so job control works.

The suite uses `set -uo pipefail` without `-e` on purpose: it must continue past
a failing check to print a full pass/fail tally. It exits nonzero if any check
failed. It runs on demand as `tests/verify.sh`, and is not a CI target; this is a
single-host tool.

## Rollout

1. Write `~/.config/sbx/sbx.conf` and `~/.local/bin/sbx`.
2. Run the verification suite against a scratch directory.
3. Use it for one real agent session with a project that has no uncommitted work,
   to surface missing mounts.
4. Add bind lines only in response to a concrete failure, not speculatively.

## Open questions

None. The deferred named-profile mechanism is documented above as an explicit
future extension rather than an unresolved decision.
