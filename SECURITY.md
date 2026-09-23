# SECURITY.md

## What this is

`sbx` builds a bubblewrap mount namespace that caps an agent's filesystem blast
radius. It is an **accident-prevention tool**, not a containment mechanism.

**It constrains an agent acting on misread instructions. It does not confine
hostile code.** If the code you run is adversarial, this is the wrong tool.

## Threat model

| In scope | Out of scope |
| --- | --- |
| Agent misreading instructions and deleting/reading the wrong host paths | Deliberate escape attempts |
| Over-eager tool use reaching outside the project | Kernel/bwrap vulnerabilities |
| Credential directories leaking into a session by default | Supply-chain isolation (packages are not gated) |
| Writes outside the project surviving the run | Network restriction (namespace is shared by default) |

The property enforced is *host paths outside the project are unreachable*, not
*everything inside the project is safe*. An agent that can write the project can
plant files there.

## What actually holds

- **Writes outside the project are discarded.** `/tmp`, `/var/tmp`, `/var/cache`,
  `/var/log`, `/run`, and `$HOME` are tmpfs (`bin/sbx:193,221-223`).
- **The host toolchain is read-only.** `/usr`, `/etc`, `/opt` and the project are
  the only meaningful bind sources; usrmerge symlinks are recreated explicitly.
- **Sockets and session buses are absent.** `/run/user/$UID` is not mounted, so
  ssh-agent, gpg-agent, D-Bus, and X11/Wayland are unreachable.
- **A build failure is a hard failure.** There is no unsandboxed fallback, by
  design. Do not add one.
- **Terminal hijack is blocked.** `--new-session` keeps the sandboxed command
  from injecting keystrokes into the parent shell (`bin/sbx:273-280`).
- **Namespaces.** pid, ipc, uts, and cgroup are unshared; `--die-with-parent`
  ties the sandbox lifetime to the wrapper.

## What does NOT hold — read this before trusting it

1. **Same UID as you.** The sandbox runs as the invoking user. Anything the
   sandbox can read is readable *as you*, and a setuid binary or a
   writable-by-you helper reachable through a read-only bind can act with your
   full host authority. This is not a privilege boundary.
2. **Writable paths are writable, period.** The project bind is `--bind`, not a
   copy. An `rw_bind` entry, or anything reachable under one, can be modified.
   `hide` only overlays a path with tmpfs; overlaying a subdirectory leaves the
   parent writable.
3. **`--agent` exposes live credentials.** The mounted config holds provider API
   keys, and everything the sandboxed command runs, including every skill script,
   can read them. This is the flag's purpose, not a bug.
4. **Config mistakes fail open in the mount plan, though not in the parser.**
   Unknown keys and bad toggles are fatal (exit 2, with a line number). But a
   *valid* spec that omits or mis-scopes a path silently provides less (or more)
   access than you intended. Review with `sbx check <dir>`.
5. **The network is shared.** Exfiltration and package downloads are both
   possible. Set `network = off` to unshare, accepting that installs break.
6. **A malformed `~/.config/crush/crush.json` breaks every Crush launch**, sandboxed
   or not, with `invalid JSON in config file` and no line number. Check that file
   parses before blaming the sandbox.

## Guidance

**Default to the plain spec.** `sbx run <dir> -- <cmd>` exposes no credentials.
Reach for `--agent` only for sessions you trust with your API keys.

**Verify the boundary, don't assume it.**

```sh
bin/sbx check <dir>            # the exact bwrap argv for `run`
bin/sbx check --shell <dir>    # the interactive plan (drops --new-session)
tests/verify.sh                # attempted-violation suite
```

**If you need real containment**, combine this with a dedicated unprivileged
user. A UID boundary survives a wrong mount plan and closes the setuid gap that
the shared-UID model leaves open. The mount plan and the UID solve different
halves of the problem; keeping both is coherent.

**Do not add a path under `$HOME` via `ro_bind`.** It is emitted before the
`$HOME` tmpfs and is silently erased. Use `ro_file` (one file, parent created
empty) or `ro_dir` (whole tree; exposes the entire subtree read-only).

**Never reintroduce an unsandboxed fallback.** Check 13 in `tests/verify.sh`
guards against it.

## Docker as an alternative

A container runtime is the natural comparison. It is not a drop-in replacement
for the use case here, but it is the right tool when the requirement shifts.

**Pros of Docker/Podman**

- **Stronger boundary.** A container can carry its own UID mapping and a real
  seccomp/AppArmor profile, so a misconfigured mount does not automatically mean
  access as the invoking user. `--read-only`, `--cap-drop=ALL`, and
  `--security-opt=no-new-privileges` have no direct equivalent in a bwrap argv.
- **Pinned, reproducible image.** The agent's toolchain becomes a versioned
  artifact rather than whatever the host currently has. That is real supply-chain
  value that a read-only bind of `/usr` cannot provide.
- **Network policy.** `--network none` or a user-defined network with egress
  rules is far easier to reason about than a namespace toggle.
- **Familiar lifecycle.** Volumes, images, and cleanup are well-trodden; the
  mental model is widely shared.

**Cons for this workflow**

- **Weight and latency.** An image with python/node/gcc/torch baked in is 2-6GB;
  the alternative is read-only host binds, which reintroduce the same fragility
  `sbx` is trying to avoid. Startup is 1-3s per invocation versus ~200ms, and an
  agent issuing hundreds of short shell calls pays that repeatedly.
- **The writable-project grant is the same problem.** `-v "$PWD:$PWD"` is a bind
  mount with the same semantics as `--bind`, and an in-container UID that does
  not match yours produces rw/ownership surprises rather than a safety win.
- **A daemon and a socket.** If `docker` runs via a root daemon, the client needs
  access to `/var/run/docker.sock`, which is equivalent to root on the host. That
  is a strictly larger trust surface than a setuid-free `bwrap` invocation.
- **Rootless setups still need configuration.** Subuid/subgid ranges, user
  namespaces, and fuse-overlayfs are moving parts that `sbx` does not have.

**Recommendation.** Stay with `sbx` when the goal is capping accidental
filesystem access for an agent on your own machine, and especially when startup
latency matters. Move to a container runtime when you need a pinned toolchain, a
genuine UID/seccomp boundary, or egress control. The two compose: `sbx` can run
`docker` as the sandboxed command, though that trades startup cost back in.

### User Mode Linux (UML) and other kernel-in-userspace options

UML runs a real Linux kernel as an ordinary unprivileged process, booting a small
image on top of it. It is a genuine kernel boundary with no root, no KVM, and no
daemon, which is exactly the gap a container runtime does not fill on a host
where you cannot create a user, cannot use rootless podman cleanly, and have no
`/dev/kvm`.

- **Pro:** a setuid binary inside the guest means nothing to the host, closing the
  shared-UID escalation gap directly. The guest carries its own libc and
  toolchain, so the usrmerge symlinks and the `systemd-resolved` workaround are
  unnecessary. Episode state dies with the process.
- **Con:** every guest syscall traps into a userspace process, so compiled-language
  and IO-heavy agent workloads are slower than both KVM and plain namespaces. It
  depends on host `PTRACE` access, so a strict `ptrace_scope` or host-level
  seccomp filter can prevent it starting at all. There is no image ecosystem, and
  booting a whole kernel makes you responsible for patching that guest kernel on
  your own schedule, which is a regression for a tool whose selling point is
  "nothing to maintain."
- **The same niche today:** gVisor (`runsc`) is the maintained incarnation of
  "syscall-interposition boundary without KVM" and composes with existing
  container tooling. Prefer it over UML unless you specifically need a real guest
  kernel.

For this project the tradeoff does not favor UML: the threat here is filesystem
accidents, which namespaces already cover at ~200ms with no image, and UML's cost
is paid on precisely the many-short-commands workload that made Podman
unattractive. Reach for it only for the no-root/no-KVM containment tier.

## Secret handling

- `--agent` copies `~/.local/share/crush` to a `mktemp -d` under `/tmp`, binds the
  copy writable, and points `XDG_DATA_HOME` at it. The files stay `0600` and the
  copy is deleted on exit via the `EXIT` trap (`bin/sbx:306-310`).
- `cmd_run` deliberately does **not** `exec` bwrap, precisely so that trap runs.
  With `exec`, the session copy would persist in `/tmp` holding live API keys.
  Do not "simplify" this back into `exec`.
- A `SIGKILL` cannot run a handler, so copies older than a day are swept at
  startup (`sweep_stale_agent_data`, `bin/sbx:74-77`) as a backstop.
- Stale `*.lock` files and `locks/` are dropped from the copy; they name host
  PIDs, and the sandbox has its own pid namespace, so a stale lock can look held
  forever.
- `etc/sbx-crush.conf` is an example, not the mechanism. It exposes live
  credentials and the whole skills tree read-only to **everything** run through
  the sandbox. `--agent` is the supported path; mention the exposure whenever you
  suggest that file.

## Reporting

This project does not guarantee a response. Report issues through the
repository's issue tracker. Given the model above, reports that assume hostile
containment will be closed as out of scope, but reports that the boundary is
*weaker than documented* — a path reachable that should not be, a fallback that
should not exist, a copy left in `/tmp` — are in scope and welcome.
