#!/usr/bin/env bash
# End-to-end evidence harness for: "a fork-synchronization failure on a REMOTE
# secondmate host must fail the update run".
#
# Nothing about the fork failure is stubbed: the simulated remote host runs the
# REAL bin/fm-update.sh against a REAL git fork whose bare repo rejects the push
# with a pre-receive hook, and the parent runs the REAL bin/fm-update.sh whose
# remote sweep calls the REAL bin/fm-remote-secondmate-control.sh through
# bin/fm-on.sh. Only the ssh transport and the GitHub API (gh-axi) are faked,
# exactly as the repository's own tests fake them.
#
# Usage: remote-fork-sync-e2e.sh <worktree> <commit-ish> [forkfail|ordinary]
#   forkfail  - the host's fork push is rejected (the defect under test)
#   ordinary  - the host fails for an unrelated reason (its home guard rejects
#               the id), which must stay an ordinary reported skip
set -u
WT=$1
REV=$2
MODE=${3:-forkfail}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-fork-e2e.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)   # a trailing-slash TMPDIR would leave "//" in the remote paths
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.com
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.com
export GIT_CONFIG_NOSYSTEM=1 HOME="$TMP/fakehome"
mkdir -p "$HOME"

SRC="$TMP/src"
mkdir -p "$SRC"
git -C "$WT" archive "$REV" | tar -x -C "$SRC"

# ---------------------------------------------------------------- remote host
R="$TMP/remote"
mkdir -p "$R"
git init -q --bare "$R/upstream.git"
git -C "$R/upstream.git" symbolic-ref HEAD refs/heads/main
git clone -q "$R/upstream.git" "$R/seed" 2>/dev/null
cp -R "$SRC/." "$R/seed/"
git -C "$R/seed" add -A
git -C "$R/seed" commit -qm c1
git -C "$R/seed" push -q origin main
git clone -q --bare "$R/upstream.git" "$R/fork.git"
# The operator's fork refuses the synchronizing push: a protected branch.
printf '#!/bin/sh\necho "protected fork branch" >&2\nexit 1\n' > "$R/fork.git/hooks/pre-receive"
chmod +x "$R/fork.git/hooks/pre-receive"
git clone -q "$R/fork.git" "$R/fm"
git -C "$R/fm" remote set-url origin https://github.com/operator/firstmate.git
git -C "$R/fm" config url."$R/fork.git".insteadOf https://github.com/operator/firstmate.git
git -C "$R/fm" config url."$R/upstream.git".insteadOf https://github.com/author/firstmate.git
git -C "$R/fm" config --add url."$R/upstream.git".insteadOf git@github.com:author/firstmate.git
git -C "$R/fm" config --add url."$R/upstream.git".insteadOf ssh://git@github.com/author/firstmate.git
git -C "$R/fm" remote set-head origin main >/dev/null 2>&1 || true
# Upstream moves on, so the fork genuinely needs the push that will be rejected.
printf 'authoritative advance\n' >> "$R/seed/README.md"
git -C "$R/seed" commit -qam upstream-advance
git -C "$R/seed" push -q origin main

# The remote secondmate home on that host.
mkdir -p "$R/sm1/bin" "$R/sm1/state" "$R/sm1/data"
printf 'v1\n' > "$R/sm1/AGENTS.md"
if [ "$MODE" = ordinary ]; then
  printf 'someone-else\n' > "$R/sm1/.fm-secondmate-home"
else
  printf 'sm1\n' > "$R/sm1/.fm-secondmate-home"
fi

mkdir -p "$R/hostbin"
cat > "$R/hostbin/gh-axi" <<'SH'
#!/usr/bin/env bash
[ "$1" = api ] && [ "$2" = /repos/operator/firstmate ] || exit 1
printf 'fork: true\nname: operator/firstmate\nbranch: main\nparent: author/firstmate\nparentBranch: main\n'
SH
chmod +x "$R/hostbin/gh-axi"

# --------------------------------------------------------------- the "network"
# A fake ssh that runs the decoded command on the simulated host and returns its
# exit status unchanged, the way OpenSSH does.
cat > "$TMP/fake-ssh" <<SH
#!/usr/bin/env bash
set -u
cat > /dev/null
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
root=\$(printf '%s' "\$2" | base64 --decode 2>/dev/null || printf '%s' "\$2" | base64 -D)
home=\$(printf '%s' "\$3" | base64 --decode 2>/dev/null || printf '%s' "\$3" | base64 -D)
argv_b64=\$4
decode() { printf '%s' "\$1" | base64 --decode 2>/dev/null || printf '%s' "\$1" | base64 -D; }
rargs=()
while IFS= read -r -d '' a; do rargs+=("\$a"); done < <(decode "\$argv_b64")
case "\${rargs[1]:-}" in
  update)
    PATH="$R/hostbin:\$PATH" HOME="$TMP/fakehome" \\
      FM_ROOT_OVERRIDE="\$root" FM_HOME="\$home" \\
      "\$root/bin/fm-remote-secondmate-control.sh" update "\${rargs[2]}"
    exit \$?
    ;;
  state) printf 'alive\n' ;;
  *) exit 91 ;;
esac
SH
chmod +x "$TMP/fake-ssh"

# ------------------------------------------------------------------- the parent
P="$TMP/parent"
mkdir -p "$P/home/state" "$P/home/data" "$P/fakebin" "$P/fake"
: > "$P/fake/windows"
touch "$P/home/state/.last-watcher-beat"
cat > "$P/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) cat "$FM_FAKE_DIR/windows" ;;
  display-message) printf '\n' ;;
esac
SH
chmod +x "$P/fakebin/tmux"
git init -q --bare "$P/origin.git"
git -C "$P/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$P/origin.git" "$P/seed" 2>/dev/null
printf 'v1\n' > "$P/seed/AGENTS.md"
printf 'r1\n' > "$P/seed/README.md"
mkdir -p "$P/seed/bin" "$P/seed/.agents/skills"
printf 'echo a\n' > "$P/seed/bin/tool.sh"
# fm-on.sh only dispatches commands tracked in this checkout; the parent never
# executes this copy, the remote host runs its own.
printf '#!/usr/bin/env bash\nexit 0\n' > "$P/seed/bin/fm-remote-secondmate-control.sh"
chmod +x "$P/seed/bin/fm-remote-secondmate-control.sh"
printf 's1\n' > "$P/seed/.agents/skills/note.md"
git -C "$P/seed" add -A
git -C "$P/seed" commit -qm c1
git -C "$P/seed" push -q origin main
git clone -q "$P/origin.git" "$P/main"
git -C "$P/main" remote set-head origin main >/dev/null 2>&1 || true

cat > "$P/home/state/sm1.meta" <<EOF
window=remote:sm1
endpoint_task_id=sm1
worktree=$R/sm1
project=$R/sm1
harness=claude
kind=secondmate
home=$R/sm1
remote_host=remote-mac
remote_backend=herdr
EOF
printf -- '- sm1 - remote domain (host: remote-mac; root: %s; home: %s; scope: things; projects: p; added 2026-09-03)\n' \
  "$R/fm" "$R/sm1" > "$P/home/data/secondmates.md"

# ------------------------------------------------------------------------ run
echo "\$ bin/fm-update.sh          # firstmate @ $(git -C "$WT" rev-parse --short "$REV") ($(git -C "$WT" log -1 --format=%s "$REV"))"
echo "  (fleet: one REMOTE secondmate 'sm1' on host remote-mac)"
if [ "$MODE" = ordinary ]; then
  echo "  (that host fails for an ORDINARY reason unrelated to fork sync:"
  echo "   its home guard rejects the id)"
else
  echo "  (that host's code root cannot synchronize its GitHub fork: the fork"
  echo "   rejects the push with 'protected fork branch')"
fi
echo
set +e
out=$(PATH="$P/fakebin:$PATH" FM_FAKE_DIR="$P/fake" FM_SSH_BIN="$TMP/fake-ssh" \
  FM_ROOT_OVERRIDE="$P/main" FM_HOME="$P/home" "$SRC/bin/fm-update.sh" 2>&1)
rc=$?
set -e
printf '%s\n' "$out"
echo
echo "\$ echo \$?"
echo "$rc"
rm -rf "$TMP"
exit 0
