#!/bin/sh
# test/restore.t - the two remedies for a live edit (2026-11-05): check and
# resolve name both ("keep it", "drop it"), `muster restore` drops it with
# the edit kept 30 days (never a fault), and `merge-back-hook` runs after
# a merge-back or capture lands, so the integrator can commit.
#
# Prints `ok   restore (N checks)` or `FAIL restore:` and every failure.
set -u

H_NAME=restore
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

export MUSTER_STATE_DIR="$_T/state"
S=$_T/state
cli() {
  OUT=$("$MUSTER" "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}
TK=$_T/tk
SRC=$TK/conf
DST=$HOME/.config/r
mkdir -p "$SRC/app"
echo 'source a' > "$SRC/a.conf"
echo 'source b' > "$SRC/b.conf"
git init -q "$TK"; g "$TK" add -A; g "$TK" commit -m seed
HOOK=$_T/hook
HLOG=$_T/hook.log
cfg() {   # [extra lines]: the config, grace off (the subject is remedies)
  printf 'place-grace 0m\nprofile p placed -\nplace %s %s user-editable\n%s' \
    "$SRC" "$DST" "capture $DST/app
${1:-}" | h_cfg "$_T/cfg"
}
export MUSTER_CONFIG="$_T/cfg"
cfg
cli place
expect_rc 0 "placed"
mkdir -p "$DST/app"   # the capture dir: an app makes it, git cannot

# === check offers both remedies, worded for THIS box =======================
echo 'live edit' > "$DST/a.conf"
cli check
expect_rc 3 "a live edit past the grace is a fault"
assert "the finding is unchanged" \
  has "$OUT" "fault  merge-back $DST/a.conf: a live edit not yet in the"
assert "see it" has "$OUT" "see it:   muster diff $DST/a.conf"
assert "keep it, with no hook: commit it yourself, and where" \
  has "$OUT" "keep it:  muster merge-back $DST/a.conf   (then commit it in $TK)"
assert "drop it" \
  has "$OUT" "drop it:  muster restore $DST/a.conf   (your edit is kept 30"
# shellcheck disable=SC2016  # the hook's own $1 and $2
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$1" "$2" >> %s\nexit 0\n' "$HLOG" \
  > "$HOOK"
chmod +x "$HOOK"
cfg "merge-back-hook $HOOK
"
cli check
assert "keep it, with a hook: the hook commits it" \
  has "$OUT" "keep it:  muster merge-back $DST/a.conf   (the merge-back hook"
cli run p
assert "the banner store holds the fault and no remedy line" \
  test -z "$(grep -E '(see|keep|drop) it:' "$S/config.faults" 2>/dev/null)"
cli resolve
assert "resolve: the remedies under the need" \
  has "$OUT" "drop it:  muster restore $DST/a.conf"
assert "resolve: counts needs, not remedy lines" has "$OUT" "== needs you (1)"

# === merge-back runs the hook ==============================================
cli merge-back
expect_rc 0 "merge-back with a hook that commits"
assert "the change landed in the source" \
  test "$(cat "$SRC/a.conf")" = 'live edit'
assert "the hook got the source file and its repo root" \
  test "$(cat "$HLOG")" = "$SRC/a.conf|$TK"
assert "and says it ran" has "$OUT" "hook       $SRC/a.conf: done"
printf '#!/bin/sh\nexit 1\n' > "$HOOK"
echo 'second edit' > "$DST/b.conf"
cli merge-back
expect_rc 0 "a declining hook is not a failure"
assert "declined: said, and the change stays in the work tree" \
  has "$OUT" "declined; it stays uncommitted in $TK"
printf '#!/bin/sh\nexit 4\n' > "$HOOK"
g "$TK" add -A; g "$TK" commit -m hand
echo 'third edit' > "$DST/b.conf"
cli merge-back
expect_rc 2 "a failing hook fails the merge-back, loudly"
assert "and names the hook" \
  has "$OUT" "FAILED     merge-back-hook $HOOK (exit 4)"
assert "the merge-back itself stands" \
  test "$(cat "$SRC/b.conf")" = 'third edit'
g "$TK" add -A; g "$TK" commit -m hand2
# shellcheck disable=SC2016  # the hook's own $1
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> %s\nexit 0\n' "$HLOG" > "$HOOK"
: > "$HLOG"
echo 'app made' > "$DST/app/new.json"
cli capture
assert "capture runs the hook too" \
  test "$(cat "$HLOG")" = "$SRC/app/new.json"
g "$TK" add -A; g "$TK" commit -m captured

# === the hook line ==========================================================
cfg "merge-back-hook relative/hook
"
cli placed
expect_rc 2 "a relative hook is a config error"
cfg "merge-back-hook $HOOK
merge-back-hook $HOOK
"
cli placed
expect_rc 2 "two hooks are a config error"
printf 'manage repo\nmerge-back-hook %s\n' "$HOOK" > "$_T/cfg"
cli survey
expect_rc 2 "merge-back-hook is a path line: refused on a repo-only box"
cfg

# === restore: drop the edit, keep it 30 days, never a fault ================
echo 'oops' > "$DST/a.conf"
cli restore --dry-run "$DST/a.conf"
expect_rc 0 "restore --dry-run"
assert "dry run: says what it would do" has "$OUT" "would restore $DST/a.conf"
assert "dry run: nothing changed" test "$(cat "$DST/a.conf")" = oops
cli restore "$DST/a.conf"
expect_rc 0 "restore a live edit"
assert "the source version is back" \
  test "$(cat "$DST/a.conf")" = "$(cat "$SRC/a.conf")"
_kept=$(find "$S/restored" -path "*$DST/a.conf" -type f | head -n 1)
assert "the edit is kept, verified" test "$(cat "$_kept")" = oops
cli restored list
assert "restored list shows it" has "$OUT" "$DST/a.conf"
cli displaced list
assert "and it is NOT a displaced edit" lacks "$OUT" "$DST/a.conf"
cli check
expect_rc 0 "after restore: nothing needs you"
cli placed --porcelain
assert "and the file is in sync" has "$OUT" "a.conf verdict=in-sync"
# a conflict: the source wins
echo 'upstream' > "$SRC/b.conf"; g "$TK" commit -qam up
echo 'mine' > "$DST/b.conf"
cli placed --porcelain
assert "a conflict, first" has "$OUT" "b.conf verdict=conflict"
cli check
assert "conflict: keep it means merge by hand" \
  has "$OUT" "keep it:  merge it into $SRC/b.conf by hand"
cli restore "$DST/b.conf"
assert "restore a conflict: the source wins" \
  test "$(cat "$DST/b.conf")" = upstream
# an application's new file: there is no source to put back
echo 'unwanted' > "$DST/app/junk.json"
cli restore "$DST/app/junk.json"
expect_rc 0 "restore an app's new file"
assert "it is gone from the live tree" test ! -e "$DST/app/junk.json"
assert "and kept" test -n "$(find "$S/restored" -name junk.json -type f)"
# not a live edit, not managed, not named
cli restore "$DST/a.conf"
expect_rc 0 "restore an in-sync file: nothing to do"
assert "and says so" has "$OUT" "nothing    $DST/a.conf: in-sync"
cli restore "$HOME/elsewhere"
expect_rc 2 "restore of a path no root manages"
cli restore
expect_rc 2 "restore needs paths: never everything by default"
# kept 30 days, then pruned
_old=$(find "$S/restored" -path "*$DST/a.conf" -type f | head -n 1)
touch -d '31 days ago' "$_old"
echo 'again' > "$DST/a.conf"
cli restore "$DST/a.conf"
assert "an edit kept over 30 days is pruned" test ! -e "$_old"
assert "a fresh one is kept" \
  test -n "$(find "$S/restored" -path "*$DST/a.conf" -type f)"
# and a scheduled run prunes too: the box nobody attends still forgets
_old=$(find "$S/restored" -path "*$DST/a.conf" -type f | head -n 1)
touch -d '31 days ago' "$_old"
cli run p
assert "a run prunes an edit kept over 30 days" test ! -e "$_old"

h_verdict
