#!/bin/sh
# test/manage.t - R12 step 1: what a box manages, declared. `manage repo`
# and `manage path`, one kind a line; with none, today's behaviour and a
# note. A verb, a config line or a profile of a kind not declared is
# refused, a path-only box has no implicit repo profile, profiles take
# `placed` and `place`, and merge-back and capture refuse a source that
# is not a git work tree.
#
# Prints `ok   manage (N checks)` or `FAIL manage:` and every failure.
set -u

H_NAME=manage
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

export MUSTER_STATE_DIR="$_T/state"
export MUSTER_CONFIG="$_T/cfg"
cli() {
  OUT=$("$MUSTER" "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}
mkrepo one
SRC=$_T/cfgsrc
DST=$HOME/.config/app
mkdir -p "$SRC"
echo 'a' > "$SRC/a.conf"
git init -q "$SRC"; g "$SRC" add -A; g "$SRC" commit -m seed
PLACE="place $SRC $DST user-editable"

# === no manage line: today's behaviour, and a note =========================
printf '%s\n' "$PLACE" > "$MUSTER_CONFIG"
cli survey one
expect_rc 0 "no manage line: repo verbs still run"
cli placed
expect_rc 1 "no manage line: path verbs still run (a new file)"
cli check
assert "no manage line: check notes it" \
  has "$OUT" "note   manage     none declared"
assert "and keeps the implicit profile" has "$OUT" "default"

# === manage path only ======================================================
printf 'manage path\n%s\n' "$PLACE" > "$MUSTER_CONFIG"
for _v in survey owed catch-up sync push stamp; do
  cli "$_v"
  expect_rc 2 "path only: $_v is refused"
  assert "$_v: names the missing line" has "$ERR" "no \`manage repo\` line"
done
cli check
assert "path only: no implicit repo profile" lacks "$OUT" "default"
assert "path only: no profile watches placement, noted" \
  has "$OUT" "no profile runs placed or place"
assert "no manage note once declared" \
  lacks "$OUT" "manage     none declared"
for _l in "repo one" "root $ROOT" "artifact /x a" "hold one" \
  "profile w owed 1h"; do
  printf 'manage path\n%s\n%s\n' "$PLACE" "$_l" > "$MUSTER_CONFIG"
  cli placed
  expect_rc 2 "path only: a '${_l%% *}' line is a config error"
  assert "'${_l%% *}': names its line and the missing kind" \
    has "$ERR" "cfg:3: '${_l%% *}"
done
printf 'manage path\n%s\nprofile w placed 1h one\n' "$PLACE" \
  > "$MUSTER_CONFIG"
cli placed
expect_rc 2 "a path profile with a repo selector is a config error"

# === a path profile: observe, then act =====================================
printf 'manage path\n%s\nprofile config placed -\n' "$PLACE" \
  > "$MUSTER_CONFIG"
cli check
assert "a placed profile: the note is gone" lacks "$OUT" "no profile runs"
assert "its row names what it covers" has "$OUT" "(every placed path)"
cli run config
expect_rc 1 "run placed: drift left is attention"
cli report
assert "report: the drift row, drawn by placement" \
  has "$OUT" "new        $DST/a.conf"
assert "observing placed nothing" test ! -e "$DST/a.conf"
printf 'manage path\n%s\nprofile config place -\n' "$PLACE" \
  > "$MUSTER_CONFIG"
cli run config
expect_rc 0 "run place: placed, nothing left"
assert "the file is placed" test -f "$DST/a.conf"
# A fault is the config store's (muster.config), not the profile's.
echo 'live edit' > "$DST/a.conf"
cli run config
expect_rc 0 "a pending merge-back does not fail a place profile"
assert "it is in the config store" \
  has "$(cat "$_T/state/config.faults")" "merge-back $DST/a.conf"
cli merge-back
printf 'manage path\n%s\nprofile a place -\nprofile b place -\n' \
  "$PLACE" > "$MUSTER_CONFIG"
cli run a
expect_rc 2 "two acting place profiles: run refused"
assert "and says why, in the run's stored log" \
  has "$(cat "$_T/state/a/latest.err")" "another acting profile"
cli check
assert "check: the overlap is a fault" has "$OUT" "overlap    a and b"

# === resolve on a path-only box ============================================
printf 'manage path\n%s\n' "$PLACE" > "$MUSTER_CONFIG"
cli resolve
assert "resolve: no repo step" lacks "$OUT" "== repos"
assert "resolve: the config step" has "$OUT" "== config"
cli resolve one
expect_rc 2 "resolve <repo>: refused without manage repo"
cli resolve --push
expect_rc 2 "resolve --push: refused without manage repo"

# === manage repo only ======================================================
printf 'manage repo\n' > "$MUSTER_CONFIG"
cli survey one
expect_rc 0 "repo only: survey runs"
for _v in placed place merge-back capture diff displaced; do
  cli "$_v"
  expect_rc 2 "repo only: $_v is refused"
done
cli where "$DST/a.conf"
expect_rc 2 "repo only: where is refused"
cli retire unrecorded
expect_rc 2 "repo only: retire is refused"
printf 'manage repo\n%s\n' "$PLACE" > "$MUSTER_CONFIG"
cli survey one
expect_rc 2 "repo only: a place line is a config error"
assert "and names it" has "$ERR" "is a path line"
cli check
assert "repo only: no placement note" lacks "$OUT" "no profile runs placed"

# === the line itself ========================================================
printf 'manage repo\nmanage repo\n' > "$MUSTER_CONFIG"
cli survey one
expect_rc 2 "a kind declared twice"
assert "and says so" has "$ERR" "declared twice"
printf 'manage files\n' > "$MUSTER_CONFIG"
cli survey one
expect_rc 2 "an unknown kind"
printf 'manage repo path\n' > "$MUSTER_CONFIG"
cli survey one
expect_rc 2 "two kinds on one line: refused, one a line"
printf 'manage repo\nmanage path\n%s\n' "$PLACE" > "$MUSTER_CONFIG"
cli survey one
expect_rc 0 "both: repo verbs"
cli placed
expect_rc 0 "both: path verbs"

# === merge-back and capture refuse a source outside any work tree ==========
PAY=$_T/payload
PD=$HOME/.config/pay
mkdir -p "$PAY/data"
echo 'shipped' > "$PAY/p.conf"
printf 'manage path\nplace %s %s user-editable\ncapture %s\n' \
  "$PAY" "$PD" "$PD/data" > "$MUSTER_CONFIG"
cli place
echo 'live edit' > "$PD/p.conf"
cli merge-back
expect_rc 2 "merge-back into a non-work-tree source: refused"
assert "it says why" has "$OUT" "not in a git work tree"
assert "the source is untouched" test "$(cat "$PAY/p.conf")" = shipped
assert "the live edit is untouched" test "$(cat "$PD/p.conf")" = 'live edit'
cli check
assert "check: the fault says it cannot be merged back" \
  has "$OUT" "cannot be merged back; make the edit upstream"
assert "check: and does not advise merge-back" \
  lacks "$OUT" "then muster merge-back"
mkdir -p "$PD/data"
echo 'app made' > "$PD/data/new.json"
cli capture
expect_rc 2 "capture into a non-work-tree source: refused"
assert "nothing captured" test ! -e "$PAY/data/new.json"

h_verdict
