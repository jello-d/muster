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
lacks() { case $1 in *"$2"*) return 1 ;; esac; }
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

# === increment 2: whole-directory links are MIGRATED (P12) =================
# A directory link into its OWN source directory: the directory becomes a
# real one, source files placed with baselines, and a non-source file the
# link showed (an app's runtime file, gitignored) is KEPT, not dropped.
mkdir -p "$SRC/dirlinked"
echo 'via a dir link' > "$SRC/dirlinked/d.conf"
g "$TK" add -A; g "$TK" commit -m dirlinked
echo 'runtime state' > "$SRC/dirlinked/state.log"   # ignored: not source
ln -s "$SRC/dirlinked" "$DST/dirlinked"
pl
expv "$DST/dirlinked/d.conf" migrate-dir
act place --dry-run
assert "dry-run: the directory link is still a link" test -h "$DST/dirlinked"
act place
expect_rc 0 "place migrates a directory link"
assert "migrate-dir: the link is now a REAL directory" \
  test -d "$DST/dirlinked" -a ! -h "$DST/dirlinked"
assert "migrate-dir: the source file is a placed copy" \
  same "$SRC/dirlinked/d.conf" "$DST/dirlinked/d.conf"
assert "migrate-dir: with its baseline" \
  same "$SRC/dirlinked/d.conf" "$MIR/dirlinked/d.conf"
assert "migrate-dir: the NON-source file was kept, not dropped" \
  test "$(cat "$DST/dirlinked/state.log")" = 'runtime state'
assert "migrate-dir: and it was named as kept" \
  has "$OUT" "kept       $DST/dirlinked/state.log (not source: unmanaged)"
assert "migrate-dir: no baseline for the non-source file" \
  test ! -e "$MIR/dirlinked/state.log"
assert "migrate-dir: the source tree itself is untouched" \
  test -f "$SRC/dirlinked/state.log"
assert "migrate-dir: no temp left beside it" \
  test -z "$(find "$DST" -maxdepth 1 -name '*muster-tmp*')"
pl
expv "$DST/dirlinked/d.conf" in-sync
# A copy that fails mid-migration leaves the link EXACTLY as it was. Its
# own corrupting cp: the shared stub is defined later in this file, and a
# test that silently ran the REAL cp here once passed for that reason.
mkdir -p "$_T/migcp"
# shellcheck disable=SC2016  # writing a script: its $ must stay literal
printf '#!/bin/sh\n"%s" "$@" || exit\nfor _a; do _l=$_a; done\n%s\n' \
  "$(command -v cp)" 'case $_l in *muster-tmp*) printf x > "$_l" ;; esac' \
  > "$_T/migcp/cp"
chmod +x "$_T/migcp/cp"
mkdir -p "$SRC/dirlinked2"
echo two > "$SRC/dirlinked2/e.conf"
g "$TK" add -A; g "$TK" commit -m dirlinked2
ln -s "$SRC/dirlinked2" "$DST/dirlinked2"
OUT=$(PATH="$_T/migcp:$PATH" "$MUSTER" place "$DST/dirlinked2" 2>&1); RC=$?
expect_rc 2 "a failed copy during migration is a failed write"
assert "and the directory link is left exactly as it was" \
  test -h "$DST/dirlinked2"
assert "and no half-built directory is left beside it" \
  test -z "$(find "$DST" -maxdepth 1 -name '*muster-tmp*')"
act place
assert "the next place migrates it" test ! -h "$DST/dirlinked2"
# A directory link to somewhere ELSE is not ours: named, never touched.
mkdir -p "$SRC/elsedir" "$_T/someone-else"
echo mine > "$SRC/elsedir/f.conf"
g "$TK" add -A; g "$TK" commit -m elsedir
echo theirs > "$_T/someone-else/f.conf"
ln -s "$_T/someone-else" "$DST/elsedir"
pl
expv "$DST/elsedir/f.conf" linked-dir
act place
assert "a foreign directory link is left alone" \
  test "$(readlink "$DST/elsedir")" = "$_T/someone-else"
OUT=$("$MUSTER" check 2>&1); RC=$?
expect_rc 3 "check: a foreign directory link is a FAULT"
rm -f "$DST/elsedir"
g "$TK" rm -q -r link/config/elsedir; g "$TK" commit -m unelse
act place

# === a SOURCE symlink is refused out loud, never dropped (T11) ==============
# The integrator's reproduction: a root holding a file, an executable and
# a symlink between two installed locations. It used to place the first
# two and say nothing at all about the third, which would have deleted
# commands from PATH. Now: its own verdict, a fault, named by every view.
mkdir -p "$SRC/shims" "$_T/installed"
echo 'tool' > "$_T/installed/tool"
echo 'data' > "$SRC/shims/data.conf"
printf '#!/bin/sh\n' > "$SRC/shims/toolx"
chmod 755 "$SRC/shims/toolx"
ln -s "$_T/installed/tool" "$SRC/shims/aliasx"
g "$TK" add -A; g "$TK" commit -m shims
pl
expv "$DST/shims/aliasx" source-link
expv "$DST/shims/data.conf" new
act place
expect_rc 1 "place with a source symlink: not clean"
assert "place: names the refused symlink" \
  has "$OUT" "refused    $DST/shims/aliasx: its source"
assert "place: nothing is created for it" \
  test ! -e "$DST/shims/aliasx" -a ! -h "$DST/shims/aliasx"
assert "place: its siblings are placed regardless" \
  same "$SRC/shims/data.conf" "$DST/shims/data.conf"
assert "place: the exec bit survives" test "$(mode "$DST/shims/toolx")" = 755
OUT=$("$MUSTER" check 2>&1); RC=$?
expect_rc 3 "check: a source symlink is a FAULT"
assert "check: names it, with the remedy" \
  has "$OUT" "source-link $DST/shims/aliasx: its source is a symlink"
g "$TK" rm -q link/config/shims/aliasx; g "$TK" commit -m unalias
act place
expect_rc 0 "the symlink out of the source: clean again"

# A whole-directory link whose directory holds a symlink: migrating it
# copies regular files only, so the symlink would vanish with the link.
# Refused, each entry named, the link left exactly as it was. A tracked
# symlink and an ignored one alike: the ignored one is what the link
# shows, and P12 keeps everything the link shows.
mkdir -p "$SRC/lnkdir"
echo 'x' > "$SRC/lnkdir/x.conf"
ln -s "$_T/installed/tool" "$SRC/lnkdir/cmd"
g "$TK" add -A; g "$TK" commit -m lnkdir
ln -s "$_T/installed/tool" "$SRC/lnkdir/rt.log"   # ignored, not source
ln -s "$SRC/lnkdir" "$DST/lnkdir"
pl
expv "$DST/lnkdir/x.conf" migrate-dir
expv "$DST/lnkdir/cmd" source-link
act place --dry-run
assert "dry-run: says the migration would be refused" \
  has "$OUT" "would REFUSE migrate-dir $DST/lnkdir"
act place
expect_rc 2 "a migration refused for a symlink is a failed write"
assert "migration refused: names the tracked symlink" \
  has "$OUT" "refused    $DST/lnkdir/cmd: not a regular file"
assert "migration refused: names the ignored symlink" \
  has "$OUT" "refused    $DST/lnkdir/rt.log: not a regular file"
assert "migration refused: the directory link is left as it was" \
  test "$(readlink "$DST/lnkdir")" = "$SRC/lnkdir"
assert "migration refused: no half-built directory beside it" \
  test -z "$(find "$DST" -maxdepth 1 -name '*muster-tmp*')"
g "$TK" rm -q link/config/lnkdir/cmd; g "$TK" commit -m uncmd
rm -f "$SRC/lnkdir/rt.log"
act place
expect_rc 0 "with no symlink inside, the migration goes ahead"
assert "and the link is a real directory now" \
  test -d "$DST/lnkdir" -a ! -h "$DST/lnkdir"

# === increment 2: capture, for directories an APPLICATION writes into ======
mkdir -p "$SRC/kprof"
echo 'layout one' > "$SRC/kprof/one.conf"
g "$TK" add -A; g "$TK" commit -m kprof
printf 'capture %s/kprof\n' "$DST" >> "$MUSTER_CONFIG"
act place
assert "capture dir: seeded from source" same "$SRC/kprof/one.conf" \
  "$DST/kprof/one.conf"
assert "capture dir: its files are app-owned" \
  has "$("$MUSTER" placed --porcelain)" \
  "kprof/one.conf verdict=in-sync policy=app-owned"
# The app CREATES a file.
echo 'layout two' > "$DST/kprof/two.conf"
pl
expv "$DST/kprof/two.conf" capture
act place
assert "place never takes an app's new file" test ! -e "$SRC/kprof/two.conf"
expect_rc 1 "place with a capture pending: something left, nothing failed"
assert "place does not even try (no FAILED)" lacks "$OUT" FAILED
OUT=$("$MUSTER" check 2>&1); RC=$?
expect_rc 3 "check: a pending capture is a FAULT"
assert "check says what to do" \
  has "$OUT" "fault  capture    $DST/kprof/two.conf"
_head=$(git -C "$TK" rev-parse HEAD)
act capture
expect_rc 0 "capture"
assert "capture: the app's new file is in the source working tree" \
  same "$DST/kprof/two.conf" "$SRC/kprof/two.conf"
assert "capture: NOT committed" test "$(git -C "$TK" rev-parse HEAD)" = "$_head"
assert "capture: with a baseline" same "$DST/kprof/two.conf" \
  "$MIR/kprof/two.conf"
pl
expv "$DST/kprof/two.conf" in-sync
g "$TK" add -A; g "$TK" commit -m captured
# The app CHANGES a captured file.
echo 'layout one, adjusted' > "$DST/kprof/one.conf"
pl
expv "$DST/kprof/one.conf" capture
act capture
assert "capture: an app's change reaches the source" \
  same "$DST/kprof/one.conf" "$SRC/kprof/one.conf"
g "$TK" commit -am adjusted
# The OTHER box captured and committed: the change arrives by place.
echo 'layout two, from the other box' > "$SRC/kprof/two.conf"
g "$TK" commit -am other
pl
expv "$DST/kprof/two.conf" place
act place
assert "capture dir: a source change is placed" \
  same "$SRC/kprof/two.conf" "$DST/kprof/two.conf"
# Both changed: a conflict, nothing touched.
echo 'app again' > "$DST/kprof/one.conf"
echo 'source again' > "$SRC/kprof/one.conf"
pl
expv "$DST/kprof/one.conf" conflict
act capture
act place
assert "conflict: capture and place leave live alone" \
  test "$(cat "$DST/kprof/one.conf")" = 'app again'
assert "conflict: and the source" \
  test "$(cat "$SRC/kprof/one.conf")" = 'source again'
g "$TK" checkout -- link/config/kprof/one.conf
cp "$SRC/kprof/one.conf" "$DST/kprof/one.conf"
chmod "$(mode "$SRC/kprof/one.conf")" "$DST/kprof/one.conf"
act place
# A source file git reports MODIFIED is never captured over.
echo 'mid-edit in the repo' > "$SRC/kprof/two.conf"
act place
echo 'app edit' > "$DST/kprof/two.conf"
act capture
assert "capture skips a source file modified in git" \
  has "$OUT" "modified in git"
g "$TK" checkout -- link/config/kprof/two.conf
cp "$SRC/kprof/two.conf" "$DST/kprof/two.conf"
chmod "$(mode "$SRC/kprof/two.conf")" "$DST/kprof/two.conf"
act place
# The app deletes a captured file: not deletion intent (P8), it returns.
rm -f "$DST/kprof/two.conf"
pl
expv "$DST/kprof/two.conf" missing
act place
assert "an app's deletion is restored; intent comes from the source" \
  test -f "$DST/kprof/two.conf"
# A per-file policy inside a capture directory wins.
echo 'pinned' > "$SRC/kprof/pinned.conf"
g "$TK" add -A; g "$TK" commit -m pinned
printf 'policy %s/kprof/pinned.conf repo-owned\n' "$DST" >> "$MUSTER_CONFIG"
act place
echo 'app touched it' > "$DST/kprof/pinned.conf"
pl
expv "$DST/kprof/pinned.conf" displace
act place
"$MUSTER" displaced clear --all > /dev/null
# A capture directory that is still a directory LINK (the real kanshi
# case): migrated, reported with the policy that governs it, then capture.
mkdir -p "$SRC/klink"
echo 'k1' > "$SRC/klink/k1.conf"
g "$TK" add -A; g "$TK" commit -m klink
ln -s "$SRC/klink" "$DST/klink"
printf 'capture %s/klink\n' "$DST" >> "$MUSTER_CONFIG"
pl
assert "behind its link, a capture dir's file reports app-owned" \
  has "$OUT" "klink/k1.conf verdict=migrate-dir policy=app-owned"
act place
assert "migrated to a real directory" test ! -h "$DST/klink"
echo 'k2 by the app' > "$DST/klink/k2.conf"
pl
expv "$DST/klink/k2.conf" capture
assert "an app's new file after migration does NOT reach the source alone" \
  test ! -e "$SRC/klink/k2.conf"

# capture lines are validated like policy lines.
printf 'place %s %s user-editable\ncapture /elsewhere\n' "$SRC" "$DST" \
  > "$_T/capbad"
OUT=$(MUSTER_CONFIG=$_T/capbad "$MUSTER" placed 2>&1); RC=$?
expect_rc 2 "a capture directory under no place root: refused"
printf 'place %s %s user-editable\ncapture %s/x\ncapture %s/x/\n' \
  "$SRC" "$DST" "$DST" "$DST" > "$_T/capbad"
OUT=$(MUSTER_CONFIG=$_T/capbad "$MUSTER" placed 2>&1); RC=$?
expect_rc 2 "two capture lines for one directory: refused"

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

# === nested roots: the most specific owns its subtree (P9) ===================
# The integrator's plan: an app-owned root placing INTO ~/.config beside
# the user-editable one. Without longest-prefix ownership, the outer root
# read the inner root's placed files as its own orphans, and deleted them.
# Named to sort AFTER the outer source (link/...), so `where` must choose
# the most specific root deliberately, not by alphabetical luck.
IA=$TK/zz-appconf
mkdir -p "$IA"
echo '{"app": 1}' > "$IA/settings.json"
g "$TK" add -A; g "$TK" commit -m appconf2
# Declared WITH a trailing slash: roots must normalise, or the outer root
# fails to see this one as inner and takes its files for orphans.
printf 'place %s %s/apps/code/ app-owned\n' "$IA" "$DST" >> "$MUSTER_CONFIG"
act place
assert "nested: the inner root placed its file" \
  test -f "$DST/apps/code/settings.json"
pl
expv "$DST/apps/code/settings.json" app-held
act place
assert "nested: the OUTER root did not take it as an orphan" \
  test -f "$DST/apps/code/settings.json"
OUT=$("$MUSTER" where "$DST/apps/code/settings.json" 2>&1)
assert "where: answered by the most specific root, and only it" \
  test "$OUT" = "$DST/apps/code/settings.json <- $IA/settings.json (app-owned)"
# The outer SOURCE also carrying a file in the inner root's territory.
mkdir -p "$SRC/apps/code"
echo 'outer' > "$SRC/apps/code/stray.json"
g "$TK" add -A; g "$TK" commit -m stray
pl
expv "$DST/apps/code/stray.json" shadowed
act place
assert "shadowed: never placed by the outer root" \
  test ! -e "$DST/apps/code/stray.json"
OUT=$("$MUSTER" check 2>&1); RC=$?
expect_rc 3 "check: a shadowed source is a FAULT"
g "$TK" rm -q -r link/config/apps; g "$TK" commit -m unstray
# Two roots with the SAME destination: ambiguous, refused.
printf 'place %s %s/ app-owned\n' "$IA" "$DST/apps/code" > "$_T/dupcfg"
printf 'place %s %s app-owned\n' "$AS" "$DST/apps/code" >> "$_T/dupcfg"
OUT=$(MUSTER_CONFIG=$_T/dupcfg "$MUSTER" placed 2>&1); RC=$?
expect_rc 2 "two roots sharing a destination (one with a trailing /)"
assert "and it says which" has "$OUT" "share the destination $DST/apps/code"

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
printf 'place %s %s user-editable\npolicy /elsewhere/x repo-owned\n' \
  "$SRC" "$DST" > "$_T/badcfg"
OUT=$(MUSTER_CONFIG=$_T/badcfg "$MUSTER" placed 2>&1); RC=$?
expect_rc 2 "a policy for a path under no root would never apply: refused"
assert "and says so" has "$OUT" "under no place root"
printf 'place %s %s user-editable\npolicy %s/a repo-owned\npolicy %s/a %s\n' \
  "$SRC" "$DST" "$DST" "$DST" app-owned > "$_T/badcfg"
OUT=$(MUSTER_CONFIG=$_T/badcfg "$MUSTER" placed 2>&1); RC=$?
expect_rc 2 "two policy lines for one path: refused"
for _bad in 'place a b c d' 'place a b nope' 'policy x nope' 'place a'; do
  printf '%s\n' "$_bad" > "$_T/badcfg"
  OUT=$(MUSTER_CONFIG=$_T/badcfg "$MUSTER" placed 2>&1); RC=$?
  expect_rc 2 "invalid config: $_bad"
done
OUT=$(MUSTER_CONFIG=$_T/nocfg "$MUSTER" placed 2>&1); RC=$?
expect_rc 2 "placed with no roots declared"

h_verdict
