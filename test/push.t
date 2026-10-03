#!/bin/sh
# test/push.t - `muster push`: a batch push that shows what it publishes
# and publishes nothing else. Every rule is checked against the ORIGIN
# itself, with a fixture built to break it: a tag under push.followTags,
# a second branch under push.default=matching, a diverged repo, a dirty
# one, a hook that refuses, a held box lock, a dry run with --all.
#
# Prints `ok   push (N checks)` or `FAIL push:` and every failure.
set -u

H_NAME=push
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

export MUSTER_STATE_DIR="$_T/state"
export MUSTER_CONFIG="$_T/cfg"
S=$_T/state
pu() {   # [args...]: push, into OUT / ERR / RC
  OUT=$("$MUSTER" push "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}

mkrepo ahead1
commit_file "$ROOT/ahead1" a "one" "first local commit"
mkrepo ahead2
commit_file "$ROOT/ahead2" a "two" "second repo's commit"
mkrepo dirtyahead
commit_file "$ROOT/dirtyahead" a "x" "ahead with work in progress"
echo 'wip' >> "$ROOT/dirtyahead/f"
mkrepo diverged; upstream_moves diverged
commit_file "$ROOT/diverged" mine "mine" "diverged local commit"
mkrepo clean
printf 'profile p owed 1h\n' > "$MUSTER_CONFIG"
_o1=$(origin_head ahead1) _o2=$(origin_head ahead2)
_od=$(origin_head diverged)

# === bare `muster push` only LISTS ==========================================
pu
expect_rc 1 "listing: something owes a push"
assert "listing: names the repo and its count" \
  has "$OUT" "push       ahead1: 1 commit(s)"
assert "listing: shows the commit subject" has "$OUT" "first local commit"
assert "listing: flags a dirty tree" \
  has "$OUT" "dirtyahead: 1 commit(s), and uncommitted work here"
assert "listing: says how to publish" has "$OUT" "muster push --all"
assert "listing: refuses the diverged repo, and says why" \
  has "$OUT" "refused    diverged: ahead AND behind"
assert "listing: a clean repo is not mentioned" lacks "$OUT" "clean"
assert "listing PUSHED NOTHING" \
  test "$(origin_head ahead1)" = "$_o1" -a "$(origin_head ahead2)" = "$_o2"
pu --dry-run --all
assert "--dry-run --all: still only lists" \
  test "$(origin_head ahead1)" = "$_o1"
pu --all ahead1
expect_rc 2 "--all and names together: refused"

# === a named push: exactly that repo, exactly its commit ===================
pu ahead1
expect_rc 0 "push ahead1"
assert "pushed: said so" has "$OUT" "pushed     ahead1"
assert "pushed: origin is now the local commit" \
  test "$(origin_head ahead1)" = "$(head_of "$ROOT/ahead1")"
assert "pushed: the other repo was NOT pushed" \
  test "$(origin_head ahead2)" = "$_o2"
assert "pushed: the commits shown are the ones that went" \
  has "$OUT" "first local commit"

# === never tags, never another branch =======================================
# `matching` pushes every branch that ALSO EXISTS on the origin, so the
# side branch must be there already, with new local commits on top: a
# side branch the origin never had would not be pushed by a plain `git
# push` either, and the test would pass by coincidence (it did, once).
# Published BEFORE the tag and followTags exist, or this setup push
# would publish the tag itself (it did, once).
g "$ROOT/ahead2" checkout -q -b side
commit_file "$ROOT/ahead2" s "side" "the side branch, published"
g "$ROOT/ahead2" push -q origin side
_os=$(git --git-dir="$_T/origins/ahead2.git" rev-parse side)
commit_file "$ROOT/ahead2" s "side 2" "a new commit on another branch"
g "$ROOT/ahead2" checkout -q main
commit_file "$ROOT/ahead2" b "more" "tagged commit"
g "$ROOT/ahead2" tag -a v9 -m release
g "$ROOT/ahead2" config push.followTags true
g "$ROOT/ahead2" config push.default matching
pu ahead2
expect_rc 0 "push ahead2"
assert "ahead2 went" \
  test "$(origin_head ahead2)" = "$(head_of "$ROOT/ahead2")"
assert "NEVER TAGS, even under push.followTags" \
  test -z "$(git --git-dir="$_T/origins/ahead2.git" tag)"
assert "NEVER ANOTHER BRANCH, even under push.default=matching" \
  test "$(git --git-dir="$_T/origins/ahead2.git" rev-parse side)" = "$_os"

# === --all: every candidate, never the refused ===============================
pu --all
expect_rc 1 "--all with a diverged repo left: 1"
assert "--all: the dirty-but-ahead repo went (push sends commits)" \
  test "$(origin_head dirtyahead)" = "$(head_of "$ROOT/dirtyahead")"
assert "--all: its work in progress is untouched" \
  test "$(tail -n 1 "$ROOT/dirtyahead/f")" = wip
assert "--all: the diverged repo was NOT pushed" \
  test "$(origin_head diverged)" = "$_od"
assert "--all: and was refused aloud" has "$OUT" "refused    diverged"
assert "--all: the profiles were re-run" test -s "$S/p/latest.records"

# === a push that fails is said, and not retried =============================
mkrepo hooked
commit_file "$ROOT/hooked" a "h" "refused by its hook"
printf '#!/bin/sh\necho "pre-push: not today" >&2\nexit 1\n' \
  > "$ROOT/hooked/.git/hooks/pre-push"
chmod +x "$ROOT/hooked/.git/hooks/pre-push"
_oh=$(origin_head hooked)
pu hooked
expect_rc 2 "a refused push: exit 2"
assert "the failure is named" has "$OUT" "FAILED     hooked"
assert "and nothing landed" test "$(origin_head hooked)" = "$_oh"

# === a push that LIES is caught by the verification =========================
# A git whose push exits 0 and sends nothing: only reading the
# remote-tracking ref back can tell, and that is what push does.
mkrepo liar
commit_file "$ROOT/liar" a "z" "a push that will not land"
mkdir -p "$_T/liargit"
# shellcheck disable=SC2016  # writing a script: its $ must stay literal
printf '#!/bin/sh\n%s\nexec %s "$@"\n' \
  'for _a; do [ "$_a" = push ] && exit 0; done' \
  "$(command -v git)" > "$_T/liargit/git"
chmod +x "$_T/liargit/git"
OUT=$(PATH="$_T/liargit:$PATH" "$MUSTER" push liar 2>&1 </dev/null); RC=$?
expect_rc 2 "a push that did not land: a failure"
assert "named as unverified" has "$OUT" "pushed, but origin does not read"

# === nothing owed: says so ==================================================
pu clean
expect_rc 0 "a clean repo: nothing to push"
assert "says so" has "$OUT" "nothing to push"

# === the box lock: never acts beside a running muster =======================
mkrepo locked
commit_file "$ROOT/locked" a "l" "waits for the box"
_ol=$(origin_head locked)
mkdir -p "$S"
mkdir "$S/.box-lock"
sleep 30 &
_holder=$!
echo "$_holder" > "$S/.box-lock/pid"
MUSTER_RUN_WAIT=1 pu locked
expect_rc 2 "a held box: push does not act"
assert "and nothing was pushed" test "$(origin_head locked)" = "$_ol"
kill "$_holder" 2>/dev/null
wait "$_holder" 2>/dev/null
rm -f "$S/.box-lock/pid"
rmdir "$S/.box-lock"

# === resolve: --push every time, or never ===================================
OUT=$("$MUSTER" resolve locked 2>&1 </dev/null)
assert "resolve without --push: lists the push" has "$OUT" "push       locked"
assert "resolve without --push: pushes nothing" \
  test "$(origin_head locked)" = "$_ol"
OUT=$("$MUSTER" resolve --dry-run --push locked 2>&1 </dev/null)
assert "resolve --dry-run --push: shows what would go" \
  has "$OUT" "waits for the box"
assert "resolve --dry-run --push: pushes nothing" \
  test "$(origin_head locked)" = "$_ol"
OUT=$("$MUSTER" resolve --push locked 2>&1 </dev/null); RC=$?
expect_rc 0 "resolve --push: done, nothing left"
assert "resolve --push: pushed" \
  test "$(origin_head locked)" = "$(head_of "$ROOT/locked")"
assert "resolve --push: and the list is empty after" \
  has "$OUT" "== nothing needs you"
assert "the box is free after" test ! -e "$S/.box-lock"

h_verdict
