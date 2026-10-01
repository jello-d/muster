#!/bin/sh
# test/stamp.t - R11: `muster stamp` records the set, and `muster stamp
# check` says whether a recorded result still describes the tree. Every
# way the tree can move under a long verification is driven for real.
#
# Prints `ok   stamp (N checks)` or `FAIL stamp:` and every failure.
set -u

H_NAME=stamp
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

ST=$_T/stamps
mkdir -p "$ST"
take() {   # <file> [args...]: take a stamp into <file>
  _k_f=$1; shift
  "$MUSTER" stamp "$@" > "$ST/$_k_f" 2>"$_T/err"
  RC=$?
}
chk() {   # <file> [args...]: check it, porcelain, into OUT / RC / ERR
  _k_f=$1; shift
  OUT=$("$MUSTER" stamp check --porcelain "$@" "$ST/$_k_f" 2>"$_T/err" \
    </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}

# === a stamp, and a check that holds =========================================
mkrepo one
take s1 one
expect_rc 0 "taking a stamp"
assert "one record per repo" test "$(wc -l < "$ST/s1" | tr -d ' ')" = 1
assert "the record says what it is" starts "$(cat "$ST/s1")" "stamp=1 "
assert "the full HEAD is recorded" \
  has "$(cat "$ST/s1")" "head=$(git -C "$ROOT/one" rev-parse HEAD)"
chk s1
expect_rc 0 "an untouched tree holds"
expect one verdict holds

# === every way a tree moves =================================================
echo more >> "$ROOT/one/f"
g "$ROOT/one" commit -am more
chk s1
expect_rc 1 "a commit voids the stamp"
expect one verdict moved
take s2 one

echo wip >> "$ROOT/one/f"
chk s2
expect one verdict changed
expect_rc 1 "an uncommitted edit voids it"
g "$ROOT/one" checkout -- f
chk s2
expect one verdict holds
assert "reverting the edit restores it: the fingerprint is the content" \
  test "$RC" = 0

echo staged > "$ROOT/one/g"
g "$ROOT/one" add g
chk s2
expect one verdict changed
g "$ROOT/one" rm -q --cached g
rm -f "$ROOT/one/g"

echo new > "$ROOT/one/untracked"
chk s2
expect one verdict changed
take s3 one
echo different > "$ROOT/one/untracked"
chk s3
expect one verdict changed
assert "an untracked file's CONTENT is part of the tree" test "$RC" = 1
rm -f "$ROOT/one/untracked"

echo '*.log' > "$ROOT/one/.git/info/exclude"
take s4 one
echo noise > "$ROOT/one/x.log"
chk s4
expect one verdict holds
assert "an ignored file is not part of the tree" test "$RC" = 0

# === superseded: origin moved past what was verified ========================
mkrepo two
take s5 two
upstream_moves two
chk s5
expect two verdict holds
assert "unfetched, it holds AS OF ITS FETCH, and says when" \
  test "$(field two fetched)" -gt 0
chk s5 --fetch
expect two verdict superseded
expect_rc 1 "origin moved past the stamp"
assert "the local tree did not move, so only superseded" \
  test "$(field two head_then)" = "$(field two head_now)"
echo local > "$ROOT/two/h"
g "$ROOT/two" add h
g "$ROOT/two" commit -m local
chk s5
expect two verdict moved,superseded

# BEHIND WHEN STAMPED: nothing moves during the run, and the result still
# does not describe the project's head. Found by a dry run of the release
# snippet against a real checkout, where the old definition said holds.
mkrepo late
upstream_moves late
g "$ROOT/late" fetch
take s5b late
chk s5b
expect late verdict superseded
expect_rc 1 "a gate started on a checkout already behind origin"
# AHEAD (your own unpushed release commit) is what a release looks like.
mkrepo early
echo release > "$ROOT/early/VERSION"
g "$ROOT/early" add VERSION
g "$ROOT/early" commit -m release
take s5c early
chk s5c --fetch
expect early verdict holds
expect_rc 0 "ahead of origin: origin's head is inside the tested tree"
# DIVERGED: ahead AND missing origin's commit.
upstream_moves early
chk s5c --fetch
expect early verdict superseded

# === gone, and what was never there =========================================
mkrepo three
take s6 three
mv "$ROOT/three" "$_T/three-moved"
chk s6
expect three verdict gone
mv "$_T/three-moved" "$ROOT/three"
if [ -n "$CAN_LOCK" ]; then
  chmod 000 "$ROOT/three"
  chk s6
  expect three verdict gone
  chmod 755 "$ROOT/three"
fi
take s7 nosuch
chk s7
expect nosuch verdict holds
assert "an absent repo stamped absent still holds" test "$RC" = 0
# A repo appearing where none was has MOVED, even an empty one whose HEAD
# is as unset as the absent one's was.
take s7c nosuch2
git init -q "$ROOT/nosuch"
chk s7
expect nosuch verdict moved
mkrepo nosuch2
chk s7c
expect nosuch2 verdict moved
# A file whose name starts with a dash is still part of the tree.
take s7b one
echo x > "$ROOT/one/-dashed"
chk s7b
expect one verdict changed
rm -f "$ROOT/one/-dashed"

# === several repos: one moving voids the run, and names which ===============
take s8 one two three
echo again >> "$ROOT/three/f"
g "$ROOT/three" commit -am again
chk s8
expect_rc 1 "one repo of three moved"
expect one verdict holds
expect three verdict moved

# === the stamp is self-contained, odd paths included ========================
mkdir -p "$_T/odd dir"
git init -q "$_T/odd dir/spaced"
printf 'repo spaced %s\n' "$_T/odd dir/spaced" > "$_T/odd.cfg"
MUSTER_CONFIG=$_T/odd.cfg take s9 spaced
chk s9
expect spaced verdict holds
assert "a path with a space round-trips" has "$(cat "$ST/s9")" "odd%20dir"
# The check reads the path FROM THE STAMP, not from today's config.
chk s9
expect spaced verdict holds

# === unusable stamps are exit 2, never "all holds" ===========================
: > "$ST/empty"
chk empty
expect_rc 2 "an empty stamp"
printf 'name=one verdict=holds\n' > "$ST/bogus"
chk bogus
expect_rc 2 "something that is not a stamp"
OUT=$("$MUSTER" stamp check "$ST/missing" 2>&1); RC=$?
expect_rc 2 "a stamp file that does not exist"
OUT=$(cat "$ST/s1" | "$MUSTER" stamp check - 2>/dev/null); RC=$?
expect_rc 1 "a stamp read from stdin (s1, since voided)"

# === read-only, deterministic, and one computation ==========================
mkrepo ro
touch "$ROOT/ro/f"
sleep 1
touch "$_T/marker"
take s10 ro
chk s10
assert "stamp and check write nothing to the repo" \
  test -z "$(find "$ROOT/ro" -newer "$_T/marker")"
take s11 ro
assert "two stamps of an unchanged tree differ only in when" \
  test "$(sed 's/ taken=[0-9]*//' "$ST/s10")" \
  = "$(sed 's/ taken=[0-9]*//' "$ST/s11")"
OUTT=$("$MUSTER" stamp check "$ST/s8" 2>/dev/null); RCT=$?
chk s8
assert "R10: same exit from both views" test "$RC" = "$RCT"
assert "table: a header, then a row per repo" \
  test "$(printf '%s\n' "$OUTT" | wc -l | tr -d ' ')" = 4

BASE=$(sh "$MUSTER" stamp check --porcelain "$ST/s8" 2>&1)
for _sh in dash bash ksh mksh zsh; do
  command -v "$_sh" >/dev/null 2>&1 || continue
  _o=$("$_sh" "$MUSTER" stamp check --porcelain "$ST/s8" 2>&1)
  assert "$_sh: the same check as sh" test "$_o" = "$BASE"
done

cli() {
  OUT=$("$MUSTER" "$@" 2>"$_T/err" </dev/null)
  RC=$?
}
cli stamp --bogus
expect_rc 2 "stamp: an unknown option"
cli stamp check
expect_rc 2 "stamp check: no file"
cli stamp check a b
expect_rc 2 "stamp check: two files"

h_verdict
