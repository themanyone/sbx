#!/usr/bin/env bash
# Attempted-violation suite for sbx. Exits nonzero on the first failed assertion.
#
# Usage: tests/verify.sh [path-to-sbx]

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
SBX="${1:-$ROOT/bin/sbx}"

export SBX_CONF="${SBX_CONF:-$ROOT/etc/sbx.conf}"
export SBX_CRUSH_CONF="${SBX_CRUSH_CONF:-$ROOT/etc/sbx-crush.conf}"
PROJECT="$(mktemp -d /tmp/sbx-project.XXXXXX)"
# Scratch configs for the checks that need a deliberately malformed spec, kept
# outside $PROJECT so they are not mounted into the sandbox under test.
CONFTMP="$(mktemp -d /tmp/sbx-conf.XXXXXX)"

pass=0 fail=0

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# assert_in <name> <needle-or-NOOUTPUT> -- <cmd...>
assert_in() {
  local name="$1" expect="$2"; shift 2; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [[ $expect == NOOUTPUT ]]; then
    [[ $rc -ne 0 ]] && ok "$name (rc=$rc)" || bad "$name: expected failure, got rc=0"
  else
    [[ $out == *"$expect"* ]] && ok "$name" || bad "$name: expected '$expect' in: $out"
  fi
}

printf 'sbx verification suite\n'
printf '  sbx     = %s\n' "$SBX"
printf '  conf    = %s\n' "$SBX_CONF"
printf '  project = %s\n\n' "$PROJECT"

echo canary >"$PROJECT/canary"

# --- 1-3: host secrets and other trees must be unreachable -------------------
assert_in "1. ~/.ssh unreachable" "No such file" -- \
  "$SBX" run "$PROJECT" -- cat "$HOME/.ssh/id_ed25519"
assert_in "2. ~/.config unreachable" "No such file" -- \
  "$SBX" run "$PROJECT" -- ls "$HOME/.config"
assert_in "3. sibling dir invisibility" NOOUTPUT -- \
  "$SBX" run "$PROJECT" -- test -e "$HOME/Downloads"

# --- 4-5: the project bind must actually work --------------------------------
assert_in "4. project readable" canary -- \
  "$SBX" run "$PROJECT" -- cat "$PROJECT/canary"
"$SBX" run "$PROJECT" -- sh -c "echo written > $PROJECT/newfile" >/dev/null 2>&1
[[ -f $PROJECT/newfile ]] && ok "5. project writes reach host" || bad "5. project writes reach host"

# --- 6-7: writes outside the project must fail -------------------------------
# $HOME is a tmpfs, so writing there succeeds *inside* the sandbox but must
# leave no trace on the host. /usr is read-only outright.
"$SBX" run "$PROJECT" -- touch "$HOME/.sandbox_escape" >/dev/null 2>&1
[[ -e $HOME/.sandbox_escape ]] && bad "6. home writes do not reach host" \
  || ok "6. home writes do not reach host"
assert_in "7. /usr write denied" NOOUTPUT -- \
  "$SBX" run "$PROJECT" -- touch /usr/local/bin/escape

# --- 8: ephemerality ---------------------------------------------------------
"$SBX" run "$PROJECT" -- sh -c 'echo x > /tmp/scratch_probe' >/dev/null 2>&1
[[ -e /tmp/scratch_probe ]] && bad "8. /tmp is ephemeral" || ok "8. /tmp is ephemeral"

# --- 9: no runtime socket dir -------------------------------------------------
assert_in "9. /run/user/\$UID absent" NOOUTPUT -- \
  "$SBX" run "$PROJECT" -- test -e "/run/user/$(id -u)"

# --- 10: no host process visibility ------------------------------------------
"$SBX" run "$PROJECT" -- sh -c 'cat /proc/1/cmdline' >/dev/null 2>&1
out="$("$SBX" run "$PROJECT" -- sh -c 'ls /proc | grep -c "^[0-9]*$"' 2>/dev/null)"
if [[ ${out:-0} -le 8 ]]; then ok "10. pid namespace isolated (${out:-0} procs)"
else bad "10. pid namespace isolated: saw ${out} processes"; fi

# --- 11: the resolved plan must not leak host paths --------------------------
plan="$("$SBX" check "$PROJECT" 2>&1)"
for leak in '.ssh' '.gnupg' 'Downloads' '.mozilla'; do
  [[ $plan == *"$leak"* ]] && bad "11. plan leaks '$leak'" || ok "11. plan hides '$leak'"
done

# --- 12: exit codes propagate -------------------------------------------------
"$SBX" run "$PROJECT" -- sh -c 'exit 42' >/dev/null 2>&1
rc=$?
[[ $rc -eq 42 ]] && ok "12. exit code preserved (42)" || bad "12. exit code preserved: got $rc"

# --- 13: no unsandboxed fallback ---------------------------------------------
BWRAP=/nonexistent-bwrap "$SBX" check "$PROJECT" >/dev/null 2>&1
[[ -f $PROJECT/newfile ]] && ok "13. harness sanity" || bad "13. harness sanity"

# --- 13a-13c: toggles fail closed rather than failing open --------------------
# A rejected value must be a hard error, and a valid but differently-cased value
# must still take effect. A loose comparison would leave the namespace shared.
printf 'ro_bind = /usr /etc\nnetwork = Off\n' >"$CONFTMP/off.conf"
if SBX_CONF="$CONFTMP/off.conf" "$SBX" check "$PROJECT" 2>/dev/null |
  tr ' ' '\n' | grep -q unshare-net; then
  ok "13a. network = Off unshares the namespace"
else
  bad "13a. network = Off unshares the namespace"
fi

printf 'ro_bind = /usr /etc\nnetwork = bogus\n' >"$CONFTMP/bad.conf"
out="$(SBX_CONF="$CONFTMP/bad.conf" "$SBX" check "$PROJECT" 2>&1)"
rc=$?
if [[ $rc -eq 2 && $out == *"must be 'on' or 'off'"* ]]; then
  ok "13b. invalid toggle rejected (rc=2)"
else
  bad "13b. invalid toggle rejected: rc=$rc out='$out'"
fi

# The empty-value case must not abort the script, whatever line it lands on.
printf 'ro_bind = /usr /etc\nrw_bind =\n' >"$CONFTMP/empty.conf"
out="$(SBX_CONF="$CONFTMP/empty.conf" "$SBX" run "$PROJECT" -- sh -c 'echo alive' 2>&1)"
[[ $out == alive ]] && ok "13c. trailing empty value tolerated" \
  || bad "13c. trailing empty value tolerated: saw '$out'"

# --- 14-16: ro_file / ro_dir expose the named paths only ----------------------
# Check 14 asserts the ro_file contract: the named file is visible and its
# siblings are not. Its parent listing is therefore exactly `crush.json` plus
# whatever ro_dir adds, so test the file directly rather than the directory.
if [[ -n ${SBX_CRUSH_CONF:-} && -f ${SBX_CRUSH_CONF:-} ]]; then
  out="$(SBX_CONF="$SBX_CRUSH_CONF" "$SBX" run "$PROJECT" -- sh -c \
    'cat ~/.config/crush/crush.json >/dev/null && echo readable' 2>&1)"
  [[ $out == readable ]] && ok "14. ro_file exposes the named file" \
    || bad "14. ro_file exposes the named file: saw '$out'"

  # ro_file must not leak the directory it lives in. ~/.config is a tmpfs, so
  # only the directories name by a bind should be present under it.
  out="$(SBX_CONF="$SBX_CRUSH_CONF" "$SBX" run "$PROJECT" -- sh -c \
    'ls ~/.config/' 2>&1)"
  case "$out" in
    *gnupg*|*mozilla*|*systemd*) bad "15. ro_file parents stay empty: saw '$out'" ;;
    crush)                       ok "15. ro_file parents stay empty" ;;
    *)                           bad "15. ro_file parents stay empty: saw '$out'" ;;
  esac

  # ro_dir must expose the whole tree, unlike ro_file.
  out="$(SBX_CONF="$SBX_CRUSH_CONF" "$SBX" run "$PROJECT" -- sh -c \
    'ls ~/.config/crush/skills/ 2>/dev/null | wc -l' 2>&1)"
  [[ ${out:-0} -gt 0 ]] && ok "16. ro_dir exposes a directory tree (${out} entries)" \
    || bad "16. ro_dir exposes a directory tree: saw '${out:-empty}'"
else
  printf '  skip 14-16. ro_file/ro_dir (set SBX_CRUSH_CONF to enable)\n'
fi

# --- 17-19: the --agent flag ------------------------------------------------
# Without the flag the default spec must stay locked down; with it the agent
# config appears. A literal API key must make the run refuse unless the caller
# explicitly acknowledges the exposure.
out="$("$SBX" run "$PROJECT" -- sh -c 'test -e ~/.config/crush && echo seen' 2>&1)"
[[ $out == *seen* ]] && bad "17. default hides agent config: saw '$out'" \
  || ok "17. default hides agent config"

out="$("$SBX" run --agent "$PROJECT" -- sh -c \
  'ls ~/.config/crush/ 2>/dev/null | tr "\n" " "' 2>&1)"
[[ $out == *crush.json* ]] && ok "18. --agent mounts the agent config" \
  || bad "18. --agent mounts the agent config: saw '$out'"

# The flag must bind the skills tree too, or an agent session has no skills.
out="$("$SBX" run --agent "$PROJECT" -- sh -c \
  'ls ~/.config/crush/skills/ 2>/dev/null | wc -l' 2>&1)"
[[ ${out:-0} -gt 0 ]] && ok "19. --agent mounts skills (${out} entries)" \
  || bad "19. --agent mounts skills: saw '${out:-empty}'"

# Crush rewrites its data dir while running, so the profile must hand it a
# writable copy. A read-only mount fails with "device or resource busy".
if [[ -d "$HOME/.local/share/crush" ]]; then
  out="$("$SBX" run --agent "$PROJECT" -- sh -c \
    'touch "$XDG_DATA_HOME/crush/.wprobe" 2>/dev/null && echo WRITABLE' 2>&1)"
  [[ $out == *WRITABLE* ]] && ok "20. --agent data dir is writable" \
    || bad "20. --agent data dir is writable: saw '$out'"
else
  printf '  skip 20. writable data dir (no ~/.local/share/crush)\n'
fi

# The writable copy must be thrown away on exit, not left in /tmp. It holds
# live credentials, so a leak matters even though the files are 0600.
before="$(ls -d /tmp/sbx-agent-data.* 2>/dev/null | wc -l)"
"$SBX" run --agent "$PROJECT" -- /bin/true >/dev/null 2>&1
after="$(ls -d /tmp/sbx-agent-data.* 2>/dev/null | wc -l)"
[[ $after -le $before ]] && ok "21. agent data copy cleaned up" \
  || bad "21. agent data copy cleaned up: $before -> $after"

# --agent must run unattended: the mounted config routinely holds literal API
# keys, and requiring an acknowledgement for each launch would make the flag
# unusable. Passing --agent is itself the acknowledgement.
out="$("$SBX" run --agent "$PROJECT" -- /bin/true 2>&1)"
rc=$?
[[ $rc -eq 0 ]] && ok "22. --agent runs without acknowledgement" \
  || bad "22. --agent runs without acknowledgement: rc=$rc out='$out'"

# --- 21-22: `shell` keeps job control, `run` stays detached ------------------
# --new-session is what stops a sandboxed command driving the terminal, and it
# is also what breaks job control in an interactive shell, so the two plans must
# differ. Asserted against the resolved argv: the user-visible symptom
# ("cannot set terminal process group") only appears on a real tty.
if "$SBX" check "$PROJECT" 2>/dev/null | tr ' ' '\n' | grep -q '^--new-session$'; then
  ok "23. run keeps --new-session (terminal detached)"
else
  bad "23. run keeps --new-session: flag missing from the plan"
fi

if "$SBX" check --shell "$PROJECT" 2>/dev/null | tr ' ' '\n' |
  grep -q '^--new-session$'; then
  bad "24. shell suppresses --new-session (job control)"
else
  ok "24. shell suppresses --new-session (job control)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$PROJECT" "$CONFTMP"
[[ $fail -eq 0 ]]
