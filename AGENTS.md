# AGENTS.md

Guidance for agents working in this repository.

## What this is

`sbx` is a single bash wrapper around `bubblewrap` that runs a command
(typically a coding agent CLI) inside an ephemeral mount namespace where the
only writable host path is one project directory. Everything written elsewhere
is tmpfs and is discarded on exit.

Fedora-only. It depends on the usrmerged layout and on `systemd-resolved`'s
non-stub resolver file. There is no unsandboxed fallback: if the sandbox cannot
be built, the script fails.

## Layout

```
bin/sbx                              the entire implementation (one file, ~400 lines)
etc/sbx.conf                         default sandbox spec (mount plan)
etc/sbx-crush.conf                   variant spec that also exposes Crush credentials
tests/verify.sh                      attempted-violation test suite
docs/superpowers/specs/specs.md
                                     design doc: decisions, mount ordering rationale, non-goals
```

There is no build step, no package manifest, and no CI. Everything is shell.

`--agent` is the supported way to give an agent its config, and it does not read
`etc/sbx-crush.conf`. That file remains as a hand-editable example: `--agent`
appends the same paths from `AGENT_RO_FILE`/`AGENT_RO_DIR` in `bin/sbx`. Keep the
two in sync when adding a path.

## Commands

```sh
tests/verify.sh                       run the full suite (30 checks)
tests/verify.sh /path/to/sbx          test a specific binary instead of ./bin/sbx
bash -n bin/sbx && bash -n tests/verify.sh    syntax check (no shellcheck installed here)
bin/sbx check <dir>                   print the resolved bwrap argv, run nothing
bin/sbx check --shell <dir>           print the interactive (job-control) plan
bin/sbx run <dir> -- <cmd> [args...]  run a command with <dir> writable
bin/sbx shell <dir>                   interactive shell
bin/sbx run --agent <dir> -- <cmd>    same, plus the agent's config and skills
```

`tests/verify.sh` uses `set -uo pipefail` (deliberately **no** `-e`) because it
must keep going after a failing check to print a full pass/fail tally. It exits
nonzero if any check failed; the exit code of the last `[[ $fail -eq 0 ]]` is
the suite's answer. Individual checks are named `n. description` so failures are
greppable.

The suite exports `SBX_CONF` and `SBX_CRUSH_CONF` to point at the repo's
`etc/` files rather than `~/.config/sbx/sbx.conf`, and runs against a
`mktemp -d` scratch directory containing a `canary` file. Checks 14-16 are
skipped unless `SBX_CRUSH_CONF` names an existing file; checks 17-20 always run
and exercise the `--agent` flag, which needs no environment prefix.

Install (for reference, not for agents to run unprompted):

```sh
install -Dm755 bin/sbx ~/.local/bin/sbx
install -Dm644 etc/sbx.conf ~/.config/sbx/sbx.conf
```

## Architecture and data flow

`bin/sbx` is one file with four sections marked by banner comments: config
parsing, plumbing, commands, entry point.

1. `main` requires `bwrap` on `PATH` (`BWRAP` env override), traps the
   `RESOLV_TMP` cleanup, then:
2. `split_flags` strips `--agent` from `argv` into the `AGENT_PROFILE` scalar and
   rewrites the global `CMD_ARGS`, which `main` reinstates with `set --`. The
   flag is only recognised **before** `--`, so a command can still receive its
   own `--agent` argument. This is why `main` uses `CMD_ARGS` rather than a
   return value: bash cannot return an array from a function.
3. `parse_conf "$SBX_CONF"` reads `$HOME/.config/sbx/sbx.conf` by default
   (`SBX_CONF` env override) into the global arrays `RO_BIND`, `RW_BIND`,
   `RO_FILE`, `RO_DIR`, `HIDE`, `ENVX` and the scalars `UNSHARE_*`, `NETWORK`.
   Toggle scalars are validated by `parse_toggle`, which normalises case and
   returns the value in `REPLY`.
4. `prepare_resolv` snapshots the real upstream resolver into `RESOLV_TMP`.
5. `sweep_stale_agent_data` removes abandoned session copies from `/tmp`; see
   below for why they can be abandoned.
6. `prepare_agent_data` copies Crush's data dir into `AGENT_DATA_TMP` and sets
   `AGENT_DATA_HOME` to point at it. The copy must exist before `build_argv`,
   which reads both to emit the bind and the `XDG_DATA_HOME` override.
7. `enable_agent_profile` appends `AGENT_RO_FILE`/`AGENT_RO_DIR` to `RO_FILE` and
   `RO_DIR`. It runs after `parse_conf` so the profile adds to the spec rather
   than replacing it.
8. The subcommand builds the argument vector with `build_argv` and either runs it
   (`run`, `shell`) or prints it shell-quoted (`check`).

### Why `--agent` needs a writable copy of the data dir

Crush's data dir is not read-only in practice: it rewrites `crush.json` and
`projects.json` and takes lock files while running. Mounting the host directory
read-only fails with `device or resource busy` on the first write, and mounting
it writable would let a sandboxed agent edit the host's real credentials and
model selection. So `prepare_agent_data` copies the tree to a `mktemp -d` under
`/tmp`, binds that writable, and sets `XDG_DATA_HOME` to it.

Two details are load-bearing:

- The copy must contain a `crush/` subdirectory (`$AGENT_DATA_TMP/crush`),
  because `XDG_DATA_HOME` names the *parent* of `crush/`. Pointing it at the
  temp dir root instead makes Crush look in `/tmp/crush` and find nothing.
- `*.lock` files and `locks/` are deleted from the copy. They name host PIDs,
  and the sandbox has its own pid namespace, so a stale lock can look held
  forever.

The agent's config dir is mounted read-only; only the data dir is writable.
Listing the data-dir files in `AGENT_RO_FILE` as well would mount them read-only
over the copy and reintroduce the busy failure, which is why they were removed
from that array.

### Session copies are cleaned up without `exec`

`cmd_run` deliberately does **not** `exec` bwrap. `exec` replaces the wrapper
process, so the `EXIT` trap never runs and the session copy, which holds live
API keys, would be left in `/tmp` indefinitely. It runs bwrap as a child, waits,
calls `cleanup`, and exits with the child's status. `--die-with-parent` still
guarantees the sandbox dies with the wrapper, and stdin/stdout/stderr, exit-code
propagation, and `SIGINT` all still behave correctly.

A `SIGKILL` cannot run any handler, so `sweep_stale_agent_data` removes copies
older than a day at startup as a backstop. Do not "simplify" this back into
`exec`; the leak is silent and the files are 0600 but durable.

### There is deliberately no secret guard

An earlier revision refused to run `--agent` when the mounted config held a
literal API key, requiring `SBX_ALLOW_SECRETS=1` to proceed. That was removed:
Crush's provider keys legitimately live as literals in `crush.json`, so the
guard fired on every launch and made the flag unusable for its intended purpose.
Passing `--agent` is itself the acknowledgement that the agent may read those
keys.

Do not reintroduce it without a concrete threat model. The exposure is real but
already explicit: it is what the flag is for, it is documented at every
user-facing entry point, and the code that used to check for it added a second
code path through `run`, `shell`, and `check` for no practical gain. The bounds
that still hold are the meaningful ones: the config dir and skills are
read-only, and the writable data dir is a discarded temp copy.

`build_argv` emits one argv element per line; `cmd_check` reads those lines back
with `read` and prints them with `%q`. `cmd_run` reads them the same way and
`exec`s the array. If you add a `printf` to `build_argv`, keep the
one-element-per-line contract or both callers break.

`cmd_shell` is just `cmd_run ... -- "$SHELL" -i`.

### Mount ordering is load-bearing

Three orderings in `build_argv` were discovered through real failures and are
commented in place. Do not reorder without re-reading
`docs/superpowers/specs/specs.md`:

1. `ro_file` bindings appear **twice**: once before the `--tmpfs $HOME`, and
   again after it. The `~` tmpfs would otherwise erase the empty parent
   directories created for files under the home tree. `ro_dir` is emitted once,
   after the tmpfs, for the same reason.
2. The resolver bind must come **after** the `/run` tmpfs, or the tmpfs wipes
   `/run/systemd/resolve`.
3. The project bind must come **last**, so it lands on top of the scrubbed home.

`ro_bind` entries are emitted **before** the `$HOME` tmpfs, so a `ro_bind` under
the home directory is silently erased. Paths under `~` must use `ro_file` (single
file) or `ro_dir` (whole tree) instead.

The usrmerge symlinks (`/bin` → `usr/bin`, `/sbin`, `/lib`, `/lib64`) are
recreated explicitly; without them nothing is executable inside the sandbox.

`--new-session` is emitted only when `INTERACTIVE != 1`, i.e. everything except
`cmd_shell`. The flag detaches from the controlling terminal, which is what
stops a sandboxed agent injecting keystrokes into the parent shell, but it also
costs job control: an interactive shell then prints `cannot set terminal process
group` and `no job control in this shell` on every startup. Do not "simplify"
this into one unconditional flag; the two modes need different argv, and
`cmd_check` therefore takes a `--shell` variant to stay faithful.

### Config format

Flat `key = value` lines, `#` starts a comment, blank lines ignored. Repeatable
keys (`rw_bind`, `ro_file`, `ro_dir`, `hide`, `env`) append across lines; a single
line may also list several space-separated values. `ro_bind` is not repeatable,
it replaces. **Unknown keys are a hard error** (`die`, exit 2) by design, so a
typo cannot silently weaken the sandbox; likewise a line without `=` is a parse
error. Missing `ro_bind` paths only warn and are skipped, because `/opt` is
commonly absent.

The four toggle keys go through `parse_toggle`, which accepts only `on`/`off`
(case-insensitively) and is fatal otherwise. Loosening this would reintroduce a
fail-open bug: `build_argv` compares `[[ $NETWORK == off ]]`, so a value like
`Off` or `false` compares unequal and silently leaves the namespace shared,
which is exactly the class of mistake the unknown-key rule exists to prevent.
`parse_toggle` returns its result in the global `REPLY` rather than printing it,
so the call does not fork a subshell.

An **empty value is legal** for the repeatable keys and means "no entries", e.g.
the bare `rw_bind =` line that ships in both specs. Every `case` branch in
`parse_conf` must therefore end in a command returning 0. The original
`[[ -n $val ]] && read ... && ARR+=(...)` form returns 1 for an empty value;
because the loop body's last command sets the function's exit status, `set -e`
then aborts the whole script with **no error message** (exit 1) whenever the last
line of the config has an empty value. `etc/sbx.conf` masked this for a long time
only because a non-empty `hide`/`env` line happened to follow `rw_bind =`. Use
`if [[ -n $val ]]; then ...; fi`, not the `&&` chain.

`ro_file` vs `ro_dir`: `ro_file` creates the parent directory **empty** and mounts
one file, so siblings stay invisible. That also means a `ro_file` inside a
directory you want listed will show an empty directory. Use `ro_dir` for trees
that must be visible in full (Crush's `skills/`), and note that it exposes the
entire subtree read-only.

Config values undergo no shell expansion. `read` does not expand a tilde and
neither does `bwrap`, so `parse_conf` calls `expand_home` on every whitespace
separated word: a leading bare `~` or `~<slash>` becomes `$HOME`, and `~user` is
deliberately left alone. A tilde that is not at the start of a word is
untouched, so paths containing `~` mid-string are not mangled.

If you add a path-like key, route it through `expand_home` the same way or it
will silently fail the `[[ -e ]]`/`[[ -f ]]` checks in `build_argv` and be
skipped with only a warning. This is exactly the bug that made every `ro_file`
entry in `etc/sbx-crush.conf` a no-op.

### DNS

The host `/etc/resolv.conf` points at `systemd-resolved`'s stub on
`127.0.0.53`, which is unreachable from inside the sandbox (network namespace is
shared, but the stub listens on host loopback). The wrapper copies
`/run/systemd/resolve/resolv.conf` to a temp file and binds it over
`/run/systemd/resolve/stub-resolv.conf`. Binding over `/etc/resolv.conf`
directly fails with `Can't mount on symlink destination`, because it is a
symlink into `/run`. If network tools fail with `connection refused` on
`127.0.0.53:53`, this path is why.

## Conventions

- `set -euo pipefail` in `bin/sbx`; `set -uo pipefail` in `tests/verify.sh` (see above).
- Errors go through `die` (exit 2, `sbx:` prefix) and `warn` (stderr, continues).
  Use them rather than raw `echo`; all diagnostics are on stderr so `check`
  output stays pipeable.
- Internal helpers are lowercase (`build_argv`, `resolve_project`), entry points
  are `cmd_<subcommand>`, `main` dispatches on `$1`.
- Quote everything; use `[[ ]]`, `local`, and `printf` (never `echo` for data).
- Comments in `bin/sbx` explain *why*, especially mount ordering. Match that.
- `README.md` and `etc/*.conf` deliberately avoid personal absolute paths
  Use `~` in documentation and configs. Do not reintroduce machine-specific paths.
- `verify.sh` embeds `sh -c '...'` strings in single quotes so the **sandbox**
  shell expands `~`, not the test shell; a shellcheck-style suggestion to "fix"
  that quoting would change behavior. Checks 14-16 only exercise `ro_file` and
  `ro_dir` when `SBX_CRUSH_CONF` points at `etc/sbx-crush.conf`; with the default
  spec they assert the opposite, that `~/.config/crush` is unreachable.

## Gotchas

- **The sandbox is not a security boundary against hostile code.** It constrains
  an agent acting on misread instructions; see the spec's Non-goals. Do not
  present it as a containment mechanism.
- **Never add a path that runs the command unsandboxed.** A sandbox construction
  failure must always be a hard failure. Check 13 exists to guard the harness
  against regressions here.
- `etc/sbx-crush.conf` is an example, not the mechanism. `--agent` is the
  supported path and does not read it, because a spec file cannot express the
  writable data-dir copy. That file's mount list exposes live API credentials and
  the whole skills tree read-only to everything run through the sandbox; mention
  the exposure when suggesting its use.
- `~/.config/crush/crush.json` etc. are hidden by default, so Crush running
  inside `sbx` cannot authenticate and sees no skills. `--agent` is the fix;
  `ro_file` alone is not enough for skills, because the empty parent directory
  hides the `skills/` tree, which is what `ro_dir` is for.
- Crush will not run against a read-only data dir. Symptom: `Failed to update
  preferred large model: rename .../crush.json.<pid>.tmp ... device or resource
  busy`. That is the missing writable copy, not a permissions problem in the
  project.
- A bare `sbx run <dir> -- crush` without `--agent` still fails with an opaque
  `json: cannot unmarshal string into Go value of type apierror.Error`. That
  message comes from Crush's own API client and says nothing about the real
  cause, which is the missing config mount. `hint_agent_config` prints the cause
  first so the user is not left debugging a Go error.
- A malformed `~/.config/crush/crush.json` (a trailing comma is enough) makes
  **every** Crush launch fail with `invalid JSON in config file`, sandboxed or
  not, and the message does not say which line. When an agent session fails to
  load config, check that file parses before suspecting the sandbox.
- The `hide` key only overlays a path with tmpfs; a path reachable under a
  writable `rw_bind` still needs care, since a tmpfs overlay on a subdirectory
  leaves the parent writable.
- Tests assert host-side absence by checking the **host** after the command
  exits. A test that passes inside the sandbox but writes to the host is the
  exact failure mode they are designed to catch.
- `SBX_CONF`, `SBX_CRUSH_CONF`, and `BWRAP` are the only environment knobs.
  There is no opt-in variable for mounting credentials: `--agent` is the opt-in.
