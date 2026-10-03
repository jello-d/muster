#!/bin/sh
# test/resolve.t - `muster resolve`: everything safe, in order, then what
# needs a person, read FRESH. Every rung of the ladder is produced on real
# repos, and every line is checked for what it did AND what it left alone:
# above all, that nothing is ever pushed.
#
# Prints `ok   resolve (N checks)` or `FAIL resolve:` and every failure.
set -u

H_NAME=resolve
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

export MUSTER_STATE_DIR="$_T/state"
export MUSTER_CONFIG="$_T/cfg"
S=$_T/state
rs() {   # [args...]: resolve, into OUT / ERR / RC
  OUT=$("$MUSTER" resolve "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}
commit_file() {   # <repo> <file> <content> <message>
  printf '%s\n' "$3" > "$1/$2"
  g "$1" add -- "$2"
  g "$1" commit -m "$4"
}
head_of() { git -C "$1" rev-parse HEAD; }
origin_head() { git --git-dir="$_T/origins/$1.git" rev-parse main; }
lacks() { case $1 in *"$2"*) return 1 ;; esac; }

# === the ladder, one repo per rung ==========================================
mkrepo clean
mkrepo behind;   upstream_moves behind
mkrepo diverged; upstream_moves diverged
commit_file "$ROOT/diverged" mine "my work" local
mkrepo ahead
commit_file "$ROOT/ahead" mine "unpushed" local
mkrepo both;     upstream_moves both
commit_file "$ROOT/both" f "my edit of the same file" local
mkrepo dirty;    upstream_moves dirty
echo 'in progress' >> "$ROOT/dirty/f"
mkrepo gone
commit_file "$ROOT/gone" mine "unpushed, behind a dead remote" local
g "$ROOT/gone" remote set-url origin "$_T/origins/no-such.git"
printf 'profile p owed 1h\n' > "$MUSTER_CONFIG"
_b_was=$(head_of "$ROOT/behind")
_d_was=$(head_of "$ROOT/diverged")
_a_origin=$(origin_head ahead)
_d_origin=$(origin_head diverged)

# --- a dry run changes nothing, and says what it would do
rs --dry-run
expect_rc 1 "dry-run: things need a person"
assert "dry-run: would pull" has "$OUT" "would pull behind"
assert "dry-run: would rebase" has "$OUT" "would rebase diverged"
assert "dry-run: nothing moved" \
  test "$(head_of "$ROOT/behind")" = "$_b_was" \
  -a "$(head_of "$ROOT/diverged")" = "$_d_was"
assert "dry-run: no profile was run" test ! -e "$S/p/latest.meta"
assert "dry-run: the pull is not on the needs-you list" \
  lacks "$OUT" "behind: still owed"

# --- the real run
rs
expect_rc 1 "resolve: things are left for a person"
assert "pulled, and said so" has "$OUT" "pulled     behind"
assert "pull landed on origin" \
  test "$(head_of "$ROOT/behind")" = "$(origin_head behind)"
assert "rebased, and said so" has "$OUT" "rebased    diverged"
assert "the rebase kept the local work" \
  test "$(cat "$ROOT/diverged/mine")" = "my work"
assert "push: on the list, with the command" \
  has "$OUT" "push       ahead: 1 unpushed commit(s)"
assert "push: names the exact command" has "$OUT" "git -C $ROOT/ahead push"
assert "the rebased repo now owes a push, listed" \
  has "$OUT" "push       diverged:"
assert "NEVER PUSHES: the ahead repo's origin is unchanged" \
  test "$(origin_head ahead)" = "$_a_origin"
assert "NEVER PUSHES: nor the rebased repo's" \
  test "$(origin_head diverged)" = "$_d_origin"
assert "escalate: listed with the overlapping file" \
  has "$OUT" "escalate   both: both sides changed f"
assert "escalate: left untouched" \
  test "$(cat "$ROOT/both/f")" = "my edit of the same file"
assert "dirty: listed, never touched" has "$OUT" "skip       dirty:"
assert "dirty: the work in progress survives" \
  test "$(tail -n 1 "$ROOT/dirty/f")" = "in progress"
assert "unfetchable: listed as such" \
  has "$OUT" "unknown    gone: could not fetch"
assert "unfetchable: listed ONCE (the stale ref is not vouched for)" \
  test "$(printf '%s\n' "$OUT" | grep -c ' gone:')" = 1
assert "clean: not mentioned on the list" lacks "$OUT" "clean:"
assert "the list is counted" has "$OUT" "== needs you ("

# --- refresh: report says what is true NOW, not what the timer last saw
assert "refresh: the profile was run" test -s "$S/p/latest.records"
assert "refresh: the refreshed run no longer owes the pull" \
  test -z "$(grep 'name=behind ' "$S/p/latest.records" \
    | grep -v 'owed=nothing')"
assert "refresh: and the run said so" has "$OUT" "attention  p"

# --- idempotent: the second run does nothing new
_d_now=$(head_of "$ROOT/diverged")
rs
assert "second run: nothing to pull or rebase" \
  has "$OUT" "nothing to pull or rebase"
assert "second run: nothing moved" \
  test "$(head_of "$ROOT/diverged")" = "$_d_now"

# --- named repos: only those, and placement (box-wide) is not touched
rs clean
expect_rc 0 "a clean named repo: nothing needs you"
assert "named: says so" has "$OUT" "== nothing needs you"
assert "named: no config step" lacks "$OUT" "== config"

# === config: placed, and the placement leftovers listed =====================
TK=$_T/tk
mkdir -p "$TK/conf"
echo 'one' > "$TK/conf/a.conf"
echo 'two' > "$TK/conf/b.conf"
git init -q "$TK"
g "$TK" add -A
g "$TK" commit -m seed
mkdir -p "$HOME/conf"
printf 'profile p owed 1h\nrepo clean\nplace %s %s user-editable\n' \
  "$TK/conf" "$HOME/conf" > "$MUSTER_CONFIG"
rs
expect_rc 0 "config placed, nothing left"
assert "config: the new files were placed" \
  has "$OUT" "new        $HOME/conf/a.conf"
assert "config: as copies" cmp -s "$TK/conf/a.conf" "$HOME/conf/a.conf"
echo 'my live edit' > "$HOME/conf/a.conf"
rs
expect_rc 1 "a live edit: needs a person"
assert "merge-back: listed with its command" \
  has "$OUT" "merge-back $HOME/conf/a.conf: a live edit"
assert "merge-back: the live edit was NOT folded in" \
  test "$(cat "$TK/conf/a.conf")" = one
assert "merge-back: nor overwritten" \
  test "$(cat "$HOME/conf/a.conf")" = 'my live edit'
echo 'source change' > "$TK/conf/a.conf"
rs
assert "both changed: a conflict, listed" \
  has "$OUT" "conflict   $HOME/conf/a.conf"
echo one > "$TK/conf/a.conf"
echo one > "$HOME/conf/a.conf"
rs
expect_rc 0 "converged again: nothing needs you"

# === the box lock: never acts beside a running muster =======================
sleep 30 &
_holder=$!
mkdir "$S/.box-lock"
echo "$_holder" > "$S/.box-lock/pid"
MUSTER_RUN_WAIT=1 rs
expect_rc 2 "a box held by another run: resolve does not act"
assert "and says why" has "$ERR" "held this box"
kill "$_holder" 2>/dev/null
wait "$_holder" 2>/dev/null
rm -f "$S/.box-lock/pid"
rmdir "$S/.box-lock"
rs
expect_rc 0 "the box free again: resolve runs"
assert "and releases the box after" test ! -e "$S/.box-lock"

rs --bogus
expect_rc 2 "an unknown option"

h_verdict
