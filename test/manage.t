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
printf 'manage path\nplace-grace 0m\n%s\nprofile config placed -\n' "$PLACE" \
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
printf 'manage path\nplace-grace 0m\n%s\nprofile config place -\n' "$PLACE" \
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
# A profile's kind is its VERB's: a placed or place profile is a path
# line, refused on a repo-only box like `place` itself (the integrator's
# own path-only fixture broke on exactly this arm, 2026-10-07).
for _p in "profile c placed 1h" "profile c place 1h"; do
  printf 'manage repo\n%s\n' "$_p" > "$MUSTER_CONFIG"
  cli survey one
  expect_rc 2 "repo only: '$_p' is a config error"
  assert "'$_p': named as a path line" has "$ERR" "cfg:2: 'profile c' is a path"
done
printf 'manage repo\n' > "$MUSTER_CONFIG"
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
printf 'manage path\nplace-grace 0m\nplace %s %s user-editable\ncapture %s\n' \
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

# === place-grace: a fresh change is not an alarm (2026-10-14) ===============
# An edit to a placed file alerted five minutes after it was made, and
# the verdict, `converged`, needed nobody at all. So a path profile
# flags only drift UNCHANGED for place-grace (default 60m), never
# `converged`; a live edit owing a merge-back is a note, not a fault,
# for as long; and the flag's recheck judges placement live.
# Its own state: the sections above leave baselines this config does not
# declare (unlayered, rightly), which would fill the store under test.
export MUSTER_STATE_DIR="$_T/gstate"
GS=$_T/gsrc
GD=$HOME/.config/grace
mkdir -p "$GS"
echo 'one' > "$GS/one.conf"
git init -q "$GS"; g "$GS" add -A; g "$GS" commit -m seed
N_LOG=$_T/glog
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\n' "$N_LOG" > "$_T/gnotify"
chmod +x "$_T/gnotify"
gcfg() {
  printf 'manage path\nplace %s %s user-editable\nprofile g placed -\n%s' \
    "$GS" "$GD" "$1" > "$MUSTER_CONFIG"
}
grun() { MUSTER_NOTIFY=$_T/gnotify cli run g; }
glast() { grep ' muster-g' "$N_LOG" 2>/dev/null | tail -n 1; }
old() { touch -t 202001010000 "$@"; }
gcfg ''
grun
expect_rc 0 "a NEW file, just written: not yet attention"
assert "not flagged" starts "$(glast)" "clear muster-g"
old "$GS/one.conf"
grun
expect_rc 1 "the same file, unchanged past the grace: attention"
assert "flagged, as a PATH" \
  starts "$(glast)" "flag --recheck"
assert "worded as paths, not repos" has "$(glast)" "1 path(s) need attention"
cli place
MUSTER_NOTIFY=$_T/gnotify cli flag-holds muster-g
expect_rc 1 "fixed by hand: the recheck sees it LIVE, before any run"
grun
assert "and the next run clears it" starts "$(glast)" "clear muster-g"
# converged: live already equals the source; nobody needs to act, ever.
echo 'two' > "$GS/one.conf"; echo 'two' > "$GD/one.conf"
g "$GS" commit -qam two   # committed: merge-back skips a modified source
old "$GS/one.conf" "$GD/one.conf"
cli placed --porcelain
assert "converged, and old" has "$OUT" "verdict=converged"
grun
expect_rc 0 "converged is never attention"
assert "and never flagged" starts "$(glast)" "clear muster-g"
cli place
# A live edit owing a merge-back: a note within the grace, then a fault.
echo 'live edit' > "$GD/one.conf"
cli check
assert "a fresh live edit: a note" has "$OUT" "note   place      merge-back"
assert "naming the grace" has "$OUT" "needs you once unchanged for place-grace"
assert "not a fault" lacks "$OUT" "fault merge-back"
grun
assert "and not in the banner's store" \
  test ! -s "$_T/gstate/config.faults"
old "$GD/one.conf" "$GS/one.conf"
cli check
expect_rc 3 "the same edit past the grace: a fault"
assert "with its command" has "$OUT" "then muster merge-back"
grun
assert "now in the banner's store" has "$(cat "$_T/gstate/config.faults")" \
  "merge-back $GD/one.conf"
cli merge-back
# The grace is a setting.
echo 'three' > "$GS/one.conf"
touch -d '@'"$(( $(date +%s) - 5400 ))" "$GS/one.conf"   # 90m ago
gcfg 'place-grace 2h
'
grun
expect_rc 0 "place-grace 2h: a 90-minute-old change is not yet due"
gcfg 'place-grace 1h
'
grun
expect_rc 1 "place-grace 1h: the same change is due"
gcfg 'place-grace 1h
place-grace 2h
'
cli placed
expect_rc 2 "place-grace twice: a config error"
printf 'manage repo\nplace-grace 1h\n' > "$MUSTER_CONFIG"
cli survey one
expect_rc 2 "place-grace is a path line: refused on a repo-only box"

h_verdict
