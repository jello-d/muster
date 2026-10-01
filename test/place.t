#!/bin/sh
# test/place.t - config placed as COPIES (docs/placement.md, P1 to P13),
# first increment: leaf files. A real git source tree and a scratch $HOME;
# every verdict is produced by doing the thing to real files, and every
# action is checked for what it did AND what it left alone.
#
# Prints `ok   place (N checks)` or `FAIL place:` and every failure.
set -u

H_NAME=place
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

export MUSTER_STATE_DIR="$_T/state"
TK=$_T/tk
SRC=$TK/link/config
DST=$HOME/.config
MIR=$_T/state/root$DST
mkdir -p "$SRC/app" "$SRC/exe" "$SRC/shared" "$DST"
echo 'app a' > "$SRC/app/a.conf"
echo 'app b' > "$SRC/app/b.conf"
printf '#!/bin/sh\necho run\n' > "$SRC/exe/run.sh"
chmod 755 "$SRC/exe/run.sh"
echo 'repo owned' > "$SRC/shared/ro.conf"
printf '*.log\n' > "$TK/.gitignore"
git init -q "$TK"
g "$TK" add -A
g "$TK" commit -m seed
echo 'runtime junk' > "$SRC/app/junk.log"   # ignored: never source
export MUSTER_CONFIG="$_T/cfg"
cat > "$MUSTER_CONFIG" <<CFG
place $SRC $DST user-editable
policy $DST/shared/ro.conf repo-owned
CFG

pl() {   # placed --porcelain, into OUT / RC / ERR
  OUT=$("$MUSTER" placed --porcelain 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}
act() {   # <verb> [args...]: place or merge-back, into OUT / RC / ERR
  OUT=$("$MUSTER" "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}
vd() {   # <dest path>: its verdict from OUT
  printf '%s\n' "$OUT" | awk -v p="path=$(printf '%s' "$1" | sed 's/ /%20/g')" \
    '$1 == p { sub(/^verdict=/, "", $2); print $2 }'
}
expv() {   # <dest path> <verdict>: one check
  N=$((N + 1))
  _e_got=$(vd "$1")
  [ "$_e_got" = "$2" ] || fail "${1#"$DST"/}: verdict [$_e_got], want [$2]"
}
same() { cmp -s "$1" "$2"; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# === before anything is placed ===============================================
pl
expect_rc 1 "placed before anything: all new"
expv "$DST/app/a.conf" new
expv "$DST/exe/run.sh" new
expv "$DST/shared/ro.conf" new
assert "an IGNORED file in the source tree is never source" \
  test -z "$(vd "$DST/app/junk.log")"
assert "policy override: ro.conf is repo-owned" \
  has "$OUT" "shared/ro.conf verdict=new policy=repo-owned"
echo 'not added yet' > "$SRC/app/new.conf"
pl
expv "$DST/app/new.conf" new
assert "an untracked, unignored file IS source (working tree)" test "$RC" = 1

# === place ====================================================================
act place
expect_rc 0 "first place"
assert "placed: content" same "$SRC/app/a.conf" "$DST/app/a.conf"
assert "placed: a copy, never a link (P1)" test ! -h "$DST/app/a.conf"
assert "placed: the executable bit came too (P7)" \
  test "$(mode "$DST/exe/run.sh")" = 755
assert "the baseline is the content (P2)" same "$SRC/app/a.conf" \
  "$MIR/app/a.conf"
assert "the baseline carries the mode (P7)" \
  test "$(mode "$MIR/exe/run.sh")" = 755
assert "the ignored file was not placed" test ! -e "$DST/app/junk.log"
pl
expect_rc 0 "after place: everything in sync"
expv "$DST/app/a.conf" in-sync
act place
assert "a second place does nothing" test -z "$OUT"
expect_rc 0 "idempotent"

# === source changed, live untouched: place ===================================
echo 'app a v2' > "$SRC/app/a.conf"
chmod 600 "$SRC/app/b.conf"
pl
expv "$DST/app/a.conf" place
expv "$DST/app/b.conf" place
assert "a mode-only change is drift (P7)" test "$RC" = 1
act place
assert "place: the new content landed" same "$SRC/app/a.conf" "$DST/app/a.conf"
assert "place: the new mode landed" test "$(mode "$DST/app/b.conf")" = 600
assert "place: the baseline followed" same "$SRC/app/a.conf" "$MIR/app/a.conf"
g "$TK" add -A
g "$TK" commit -m v2

# === live edited, source untouched: merge-back (user-editable) ===============
echo 'live edit' >> "$DST/app/a.conf"
pl
expv "$DST/app/a.conf" merge-back
act place
assert "place never touches a merge-back: the live edit stays" \
  has "$(cat "$DST/app/a.conf")" "live edit"
# A pending merge-back is a FAULT: it is an explicit verb no apply runs,
# so as drift it would schedule an apply that could never clear it.
OUT=$("$MUSTER" check 2>&1); RC=$?
expect_rc 3 "check: a pending merge-back is a FAULT"
assert "check says what to do" \
  has "$OUT" "fault  merge-back $DST/app/a.conf: a live edit not yet"
_head=$(git -C "$TK" rev-parse HEAD)
act merge-back
expect_rc 0 "merge-back"
assert "merge-back: the edit is in the source working tree (P5)" \
  same "$DST/app/a.conf" "$SRC/app/a.conf"
assert "merge-back: NOT committed" \
  test "$(git -C "$TK" rev-parse HEAD)" = "$_head"
assert "merge-back: git shows it as a working-tree change" \
  test -n "$(git -C "$TK" status --porcelain -- link/config/app/a.conf)"
assert "merge-back: the baseline moved to it" same "$DST/app/a.conf" \
  "$MIR/app/a.conf"
pl
expv "$DST/app/a.conf" in-sync
g "$TK" commit -am merged

# A source file git reports MODIFIED is left alone (someone mid-edit).
echo 'uncommitted source' > "$SRC/app/b.conf"
act place                                  # baseline = the dirty source
echo 'live too' >> "$DST/app/b.conf"
pl
expv "$DST/app/b.conf" merge-back
act merge-back
assert "merge-back skips a source file modified in git" \
  has "$OUT" "is modified in git"
assert "and wrote nothing into it" \
  test "$(cat "$SRC/app/b.conf")" = 'uncommitted source'
g "$TK" checkout -- link/config/app/b.conf
cp "$SRC/app/b.conf" "$DST/app/b.conf"
chmod "$(mode "$SRC/app/b.conf")" "$DST/app/b.conf"
act place

# === both changed: conflict, converged =======================================
echo 'live x' > "$DST/app/a.conf"
echo 'source y' > "$SRC/app/a.conf"
pl
expv "$DST/app/a.conf" conflict
act place
act merge-back
assert "a conflict: place and merge-back leave live alone" \
  test "$(cat "$DST/app/a.conf")" = 'live x'
assert "a conflict: and the source" test "$(cat "$SRC/app/a.conf")" = 'source y'
OUT=$("$MUSTER" check 2>&1); RC=$?
expect_rc 3 "check: a conflict is a FAULT"
assert "check names it" has "$OUT" "fault  place      conflict $DST/app/a.conf"
echo 'source y' > "$DST/app/a.conf"
pl
expv "$DST/app/a.conf" converged
act place
assert "converged: the baseline is recorded" same "$SRC/app/a.conf" \
  "$MIR/app/a.conf"
g "$TK" commit -am y

# === repo-owned: a live edit is DISPLACED, never lost (P4) ==================
echo 'someone edited a repo-owned file' > "$DST/shared/ro.conf"
chmod 640 "$DST/shared/ro.conf"
pl
expv "$DST/shared/ro.conf" displace
act place
expect_rc 0 "place with a displacement"
assert "the edit was reported where it happened" has "$OUT" "displaced  $DST"
_kept=$(find "$_T/state/displaced" -type f -path "*$DST/shared/ro.conf")
assert "the edit is KEPT, content intact" \
  test "$(cat "$_kept")" = 'someone edited a repo-owned file'
assert "the edit is kept with its mode" test "$(mode "$_kept")" = 640
assert "and only then was live overwritten" same "$SRC/shared/ro.conf" \
  "$DST/shared/ro.conf"
OUT=$("$MUSTER" displaced 2>&1)
assert "displaced lists it" has "$OUT" "$DST/shared/ro.conf"
OUT=$("$MUSTER" check 2>&1); RC=$?
expect_rc 3 "check: a kept edit is a FAULT until cleared"
assert "check names it" has "$OUT" "fault  displaced  $DST/shared/ro.conf"
_run=$("$MUSTER" displaced | awk '{print $1; exit}')
OUT=$("$MUSTER" displaced clear "$_run" "$DST/shared/ro.conf" 2>&1)
assert "clear names what it removed" has "$OUT" "cleared    $DST/shared/ro.conf"
assert "and it is gone from the store" test -z "$("$MUSTER" displaced)"
OUT=$("$MUSTER" check 2>&1); RC=$?
expect_rc 0 "check once cleared"

# === deletions: intent comes from the source only (P8) =======================
mkdir -p "$SRC/deep/er"
echo deep > "$SRC/deep/er/x.conf"
g "$TK" add -A
g "$TK" commit -m deep
act place
g "$TK" rm -q link/config/deep/er/x.conf
g "$TK" commit -m 'drop x'
pl
expv "$DST/deep/er/x.conf" orphan
act place
assert "orphan: the untouched live file is removed" \
  test ! -e "$DST/deep/er/x.conf"
assert "orphan: its baseline too" test ! -e "$MIR/deep/er/x.conf"
assert "orphan: emptied parents are removed" test ! -d "$DST/deep"
assert "orphan: never the destination root itself" test -d "$DST"
rm -f "$DST/app/b.conf"
pl
expv "$DST/app/b.conf" missing
act place
assert "a LIVE deletion is not intent: the file comes back" \
  same "$SRC/app/b.conf" "$DST/app/b.conf"
# Deleted at source but edited live: user-editable conflicts...
echo gone-later > "$SRC/app/edited.conf"
g "$TK" add -A; g "$TK" commit -m e
act place
echo 'live work' >> "$DST/app/edited.conf"
g "$TK" rm -q link/config/app/edited.conf; g "$TK" commit -m rm
pl
expv "$DST/app/edited.conf" conflict
act place
assert "deleted at source, edited live: user-editable keeps it" \
  has "$(cat "$DST/app/edited.conf")" "live work"
# ...repo-owned displaces, then removes.
echo 'ro2' > "$SRC/shared/ro2.conf"
printf 'policy %s repo-owned\n' "$DST/shared/ro2.conf" >> "$MUSTER_CONFIG"
g "$TK" add -A; g "$TK" commit -m ro2
act place
echo 'edited' > "$DST/shared/ro2.conf"
g "$TK" rm -q link/config/shared/ro2.conf; g "$TK" commit -m rm2
act place
assert "repo-owned, deleted at source, edited live: removed" \
  test ! -e "$DST/shared/ro2.conf"
assert "but the edit was kept first" \
  test -n "$(find "$_T/state/displaced" -path "*shared/ro2.conf")"
"$MUSTER" displaced clear --all > /dev/null
rm -f "$DST/app/edited.conf" "$MIR/app/edited.conf"

# === migration from symlinks, and links that are not ours (P12) =============
mkdir -p "$SRC/linked"
echo 'was a link' > "$SRC/linked/l.conf"
g "$TK" add -A; g "$TK" commit -m linked
mkdir -p "$DST/linked"
ln -s "$SRC/linked/l.conf" "$DST/linked/l.conf"   # the old link model
pl
expv "$DST/linked/l.conf" migrate
act place
assert "migrate: the link became a real file" test ! -h "$DST/linked/l.conf"
assert "migrate: with the source's content" same "$SRC/linked/l.conf" \
  "$DST/linked/l.conf"
assert "migrate: and a baseline" same "$SRC/linked/l.conf" "$MIR/linked/l.conf"
echo 'elsewhere' > "$_T/elsewhere"
rm -f "$DST/app/b.conf"
ln -s "$_T/elsewhere" "$DST/app/b.conf"
pl
expv "$DST/app/b.conf" foreign
act place
assert "a foreign symlink is left exactly as it is" \
  test "$(readlink "$DST/app/b.conf")" = "$_T/elsewhere"
rm -f "$DST/app/b.conf"
act place

# A WHOLE-DIRECTORY link: the file below it is the source itself, seen
# through the link. Found live; it read as converged. Named, never acted on.
mkdir -p "$SRC/dirlinked"
echo 'via a dir link' > "$SRC/dirlinked/d.conf"
g "$TK" add -A; g "$TK" commit -m dirlinked
ln -s "$SRC/dirlinked" "$DST/dirlinked"
pl
expv "$DST/dirlinked/d.conf" linked-dir
act place
assert "linked-dir: the directory link is left as it is" \
  test -h "$DST/dirlinked"
assert "linked-dir: no baseline is recorded" test ! -e "$MIR/dirlinked/d.conf"
OUT=$("$MUSTER" check 2>&1)
assert "check: a linked-dir is a NOTE, not a fault" \
  has "$OUT" "note   place      linked-dir $DST/dirlinked/d.conf"
rm -f "$DST/dirlinked"
g "$TK" rm -q -r link/config/dirlinked; g "$TK" commit -m undirlink

# A live file muster never placed, differing from source: not ours to take.
echo 'pre-existing' > "$SRC/app/pre.conf"
g "$TK" add -A; g "$TK" commit -m pre
echo 'someone else wrote this' > "$DST/app/pre.conf"
pl
expv "$DST/app/pre.conf" conflict
act place
assert "an unplaced differing live file is not overwritten" \
  test "$(cat "$DST/app/pre.conf")" = 'someone else wrote this'
cp "$SRC/app/pre.conf" "$DST/app/pre.conf"
pl
expv "$DST/app/pre.conf" converged
act place

# === app-owned: seeded, then the application's (P10) ========================
AS=$TK/appconf
AD=$HOME/.config-apps
mkdir -p "$AS"
echo '{"theme": "dark"}' > "$AS/settings.json"
g "$TK" add -A; g "$TK" commit -m appconf
printf 'place %s %s app-owned\n' "$AS" "$AD" >> "$MUSTER_CONFIG"
pl
expv "$AD/settings.json" new
act place
assert "app-owned: seeded when absent" same "$AS/settings.json" \
  "$AD/settings.json"
echo '{"theme": "dark", "zoom": 2}' > "$AD/settings.json"
echo '{"theme": "light"}' > "$AS/settings.json"
pl
expv "$AD/settings.json" app-held
act place
assert "app-owned: never overwritten once there" \
  has "$(cat "$AD/settings.json")" zoom
g "$TK" checkout -- appconf/settings.json

# === the mass-deletion guard (P8) ===========================================
mv "$SRC" "$_T/src-away"
pl
assert "a missing source root is no-source, one record" \
  test "$(printf '%s\n' "$OUT" | grep -c "verdict=no-source")" = 1
act place
assert "a missing source root removes NOTHING" test -f "$DST/app/a.conf"
assert "nor any baseline" test -f "$MIR/app/a.conf"
OUT=$("$MUSTER" check 2>&1); RC=$?
expect_rc 3 "check: a missing source root is a FAULT"
mv "$_T/src-away" "$SRC"
mkdir -p "$_T/emptysrc"
git init -q "$_T/emptysrc"
printf 'place %s %s user-editable\n' "$_T/emptysrc" "$HOME/.empty" \
  >> "$MUSTER_CONFIG"
pl
assert "an EMPTY source root is no-source too" \
  has "$OUT" "verdict=no-source"
sed -i.bak '/emptysrc/d' "$MUSTER_CONFIG"; rm -f "$MUSTER_CONFIG.bak"

# === read-only destinations are reported, never written (P11) ===============
if [ -n "$CAN_LOCK" ]; then
  mkdir -p "$SRC/locked"
  echo locked > "$SRC/locked/l.conf"
  g "$TK" add -A; g "$TK" commit -m locked
  mkdir -p "$DST/locked"
  chmod 555 "$DST/locked"
  pl
  expv "$DST/locked/l.conf" read-only
  act place
  assert "a read-only destination is not written" \
    test ! -e "$DST/locked/l.conf"
  assert "place says read-only, it does not just fail" \
    has "$OUT" "read-only  $DST/locked/l.conf"
  assert "a read-only destination is not a failed write" test "$RC" != 2
  OUT=$("$MUSTER" check 2>&1); RC=$?
  expect_rc 3 "check: read-only drift is a FAULT"
  chmod 755 "$DST/locked"
  act place
  # A failed BASELINE write: live lands, baseline does not move (P4).
  echo more > "$SRC/locked/m.conf"
  g "$TK" add -A; g "$TK" commit -m m
  chmod 555 "$MIR/locked"
  act place
  expect_rc 2 "a write that failed is exit 2"
  assert "it says what failed" has "$OUT" "FAILED"
  assert "no baseline was recorded for it" test ! -e "$MIR/locked/m.conf"
  chmod 755 "$MIR/locked"
  pl
  expv "$DST/locked/m.conf" converged
  act place
fi

# === a copy that comes out wrong never lands (P4) ===========================
# A cp that writes a SHORT copy: the temp fails verification, so neither
# the live file nor the baseline is replaced, and the run says FAILED.
_realcp=$(command -v cp)
mkdir -p "$_T/badcp"
cat > "$_T/badcp/cp" <<BADCP
#!/bin/sh
"$_realcp" "\$@" || exit
for _a; do _last=\$_a; done
case \$_last in *muster-tmp*) printf 'trunc' > "\$_last" ;; esac
BADCP
chmod +x "$_T/badcp/cp"
echo 'a newer source' > "$SRC/app/a.conf"
_live_before=$(cat "$DST/app/a.conf")
_base_before=$(cat "$MIR/app/a.conf")
OUT=$(PATH="$_T/badcp:$PATH" "$MUSTER" place "$DST/app/a.conf" 2>&1); RC=$?
expect_rc 2 "a corrupted copy is a failed write"
assert "the live file was NOT replaced by the bad copy" \
  test "$(cat "$DST/app/a.conf")" = "$_live_before"
assert "the baseline did not move" \
  test "$(cat "$MIR/app/a.conf")" = "$_base_before"
assert "no temp file is left behind" \
  test -z "$(find "$DST/app" "$MIR/app" -name '*muster-tmp*')"
g "$TK" checkout -- link/config/app/a.conf

# A rename that claims success and lands nothing: the after-check catches
# it, so the baseline is NOT moved to describe a write that never happened.
mkdir -p "$_T/liarmv"
cat > "$_T/liarmv/mv" <<LIARMV
#!/bin/sh
for _a; do _last=\$_a; done
case \$_last in "$DST"/*) exit 0 ;; esac
exec "$(command -v mv)" "\$@"
LIARMV
chmod +x "$_T/liarmv/mv"
echo 'a newer source' > "$SRC/app/a.conf"
OUT=$(PATH="$_T/liarmv:$PATH" "$MUSTER" place "$DST/app/a.conf" 2>&1); RC=$?
expect_rc 2 "a rename that did not land is a failed write"
assert "the baseline did not move for a write that never happened" \
  test "$(cat "$MIR/app/a.conf")" = "$_base_before"
assert "and the failed write left no temp behind" \
  test -z "$(find "$DST/app" -name '*muster-tmp*')"
g "$TK" checkout -- link/config/app/a.conf

# === an EMPTY source root removes nothing, through place itself (P8) ======
ER=$_T/emptyroot
EDR=$HOME/.emptyroot
mkdir -p "$ER"
echo 'only' > "$ER/only.conf"
printf 'place %s %s user-editable\n' "$ER" "$EDR" >> "$MUSTER_CONFIG"
act place
assert "fixture: placed from a plain (non-git) root" test -f "$EDR/only.conf"
rm -f "$ER/only.conf"
act place
assert "an existing but EMPTY source root removes NOTHING" \
  test -f "$EDR/only.conf"
assert "and says why" has "$OUT" "no-source  $ER"
sed -i.bak '/emptyroot/d' "$MUSTER_CONFIG"; rm -f "$MUSTER_CONFIG.bak"

# === removing the last file under a root never removes the root ============
SR=$_T/soloroot
SDR=$HOME/.soloroot
mkdir -p "$SR"
echo a > "$SR/a.conf"
echo b > "$SR/b.conf"
printf 'place %s %s user-editable\n' "$SR" "$SDR" >> "$MUSTER_CONFIG"
act place
rm -f "$SDR/b.conf" "$SR/a.conf"
act place "$SDR/a.conf"
assert "fixture: the orphan was removed" test ! -e "$SDR/a.conf"
assert "and its now-empty destination ROOT was kept" test -d "$SDR"
sed -i.bak '/soloroot/d' "$MUSTER_CONFIG"; rm -f "$MUSTER_CONFIG.bak"

# === temp files are never content ===========================================
echo stray > "$MIR/app/.a.conf.muster-tmp.999"
pl
assert "a stray temp in the mirror is not a baseline" \
  test -z "$(vd "$DST/app/.a.conf.muster-tmp.999")"
rm -f "$MIR/app/.a.conf.muster-tmp.999"

# === where, dry-run, path filters, config =====================================
OUT=$("$MUSTER" where "$DST/app/a.conf" 2>&1); RC=$?
expect_rc 0 "where: a destination"
assert "where: names its source" has "$OUT" "<- $SRC/app/a.conf (user-editable)"
OUT=$("$MUSTER" where "$SRC/shared/ro.conf" 2>&1)
assert "where: a source names its destination and policy" \
  has "$OUT" "-> $DST/shared/ro.conf (repo-owned)"
OUT=$("$MUSTER" where /nowhere/at/all 2>&1); RC=$?
expect_rc 1 "where: a path under no root"
echo 'dry' > "$SRC/app/a.conf"
act place --dry-run
assert "dry-run says what it would do" has "$OUT" "would place"
assert "dry-run changes nothing" test "$(cat "$DST/app/a.conf")" != dry
echo 'b dry' > "$SRC/app/b.conf"
act place "$DST/app/b.conf"
assert "a named path: placed" same "$SRC/app/b.conf" "$DST/app/b.conf"
assert "an unnamed path: untouched" test "$(cat "$DST/app/a.conf")" != dry
g "$TK" checkout -- link/config
act place
for _bad in 'place a b c d' 'place a b nope' 'policy x nope' 'place a'; do
  printf '%s\n' "$_bad" > "$_T/badcfg"
  OUT=$(MUSTER_CONFIG=$_T/badcfg "$MUSTER" placed 2>&1); RC=$?
  expect_rc 2 "invalid config: $_bad"
done
OUT=$(MUSTER_CONFIG=$_T/nocfg "$MUSTER" placed 2>&1); RC=$?
expect_rc 2 "placed with no roots declared"

h_verdict
