#!/bin/sh
# test/layers.t - P14: several `place` lines into ONE destination root,
# one per layer. Ownership by the layer that supplies a file, `layered`
# when two do, a move between layers that removes nothing, removal by
# CAUSE (`orphan` while the layer is declared, `unlayered` once it is
# not), `muster retire`, the layer record and its backfill, and capture
# into the one layer holding the capture directory.
#
# Prints `ok   layers (N checks)` or `FAIL layers:` and every failure.
set -u

H_NAME=layers
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

export MUSTER_STATE_DIR="$_T/state"
export MUSTER_CONFIG="$_T/cfg"
S=$_T/state
TK=$_T/tk
BASE=$TK/link/config.base
DESK=$TK/link/config.desktop
DST=$HOME/.config
mkdir -p "$BASE/sh" "$BASE/app/data" "$DESK/wm" "$DESK/mux" "$DST"
echo 'sh' > "$BASE/sh/rc"
echo 'seed' > "$BASE/app/data/seed.json"
echo 'wm' > "$DESK/wm/wm.conf"
echo 'old' > "$DESK/wm/old.conf"
echo 'mux' > "$DESK/mux/mux.conf"
echo 'kept' > "$DESK/wm/kept.conf"
git init -q "$TK"
g "$TK" add -A
g "$TK" commit -m seed
cfg_both() {
  cat > "$MUSTER_CONFIG" <<CFG
place $BASE $DST user-editable
place $DESK $DST user-editable
policy $DST/mux/mux.conf repo-owned
capture $DST/app/data
CFG
}
cfg_both

act() {   # <verb> [args...]: into OUT / RC / ERR
  OUT=$("$MUSTER" "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}
pl() { act placed --porcelain; }
vd() {   # <dest path>: its verdict from OUT
  printf '%s\n' "$OUT" | awk -v p="path=$1" \
    '$1 == p { sub(/^verdict=/, "", $2); print $2 }'
}
expv() {   # <dest path> <verdict>
  N=$((N + 1))
  _e_got=$(vd "$1")
  [ "$_e_got" = "$2" ] || fail "${1#"$DST"/}: verdict [$_e_got], want [$2]"
}
rec() { cat "$S/layer$1" 2>/dev/null; }   # <dest>: its layer record

# === two layers into one root: each file from the layer that supplies it ====
pl
expv "$DST/sh/rc" new
expv "$DST/wm/wm.conf" new
act place
expect_rc 0 "place, two layers into one root"
assert "the base layer's file is placed" test -f "$DST/sh/rc"
assert "the desktop layer's file is placed" test -f "$DST/wm/wm.conf"
assert "the layer is recorded with the file" \
  test "$(rec "$DST/wm/wm.conf")" = "$DESK user-editable"
assert "each by its own layer" \
  test "$(rec "$DST/sh/rc")" = "$BASE user-editable"
act where "$DST/wm/wm.conf"
assert "where names the layer" \
  has "$OUT" "<- $DESK/wm/wm.conf (user-editable, layer $DESK)"
act where "$DST/mux/mux.conf"
assert "where: a per-file policy still applies by destination" \
  has "$OUT" "(repo-owned, layer $DESK)"
act check
expect_rc 0 "check: two layers in sync are clean"

# === two layers supplying one file: a fault, nothing placed =================
mkdir -p "$BASE/wm"
echo 'base wm' > "$BASE/wm/wm.conf"
g "$TK" add -A; g "$TK" commit -m overlap
pl
expv "$DST/wm/wm.conf" layered
assert "layered: names one layer" has "$OUT" "source=$BASE/wm/wm.conf"
assert "layered: and the other" has "$OUT" "also=$DESK/wm/wm.conf"
act place
assert "layered: nothing placed" test "$(cat "$DST/wm/wm.conf")" = wm
act check
expect_rc 3 "check: layered is a FAULT"
assert "check: names both layers" \
  has "$OUT" "layered $DST/wm/wm.conf: supplied by two layers"
act where "$DST/wm/wm.conf"
assert "where: layered names both" has "$OUT" "LAYERED: supplied by"
g "$TK" rm -q "$BASE/wm/wm.conf"; g "$TK" commit -m unoverlap

# === a MOVE between layers removes nothing ==================================
mkdir -p "$BASE/mux"
g "$TK" mv "$DESK/mux/mux.conf" "$BASE/mux/mux.conf"
g "$TK" commit -m move
pl
expv "$DST/mux/mux.conf" in-sync
act place
expect_rc 0 "place after a move"
assert "moved: the file stays" test -f "$DST/mux/mux.conf"
assert "moved: the record follows it to the new layer" \
  test "$(rec "$DST/mux/mux.conf")" = "$BASE user-editable"

# === removed from a layer still declared: an orphan, as ever (P8) ===========
g "$TK" rm -q "$DESK/wm/old.conf"; g "$TK" commit -m rm-old
pl
expv "$DST/wm/old.conf" orphan
act place
assert "orphan: removed" test ! -e "$DST/wm/old.conf"
assert "orphan: its record goes with it" test ! -e "$S/layer$DST/wm/old.conf"

# === a layer no longer declared: unlayered, NOTHING removed =================
# A base file deleted at the same time: an orphan of a declared layer,
# which a retire of the desktop layer must leave alone.
echo 'base gone' > "$BASE/sh/gone"
g "$TK" add -A; g "$TK" commit -m gone
act place
g "$TK" rm -q "$BASE/sh/gone"; g "$TK" commit -m rm-gone
cat > "$MUSTER_CONFIG" <<CFG
place $BASE $DST user-editable
capture $DST/app/data
CFG
pl
expv "$DST/wm/wm.conf" unlayered
assert "unlayered: the record names the layer" \
  has "$OUT" "verdict=unlayered policy=user-editable source=$DESK also"
expv "$DST/sh/gone" orphan
act place
expect_rc 1 "place with an unlayered file: something left"
assert "unlayered: nothing removed" test -f "$DST/wm/wm.conf"
assert "the orphan of the declared layer IS removed" \
  test ! -e "$DST/sh/gone"
act check
expect_rc 3 "check: unlayered is a FAULT"
assert "check: names the layer" has "$OUT" "its layer $DESK is no longer"
assert "check: and the remedy" has "$OUT" "muster retire"

# === retire: one layer, under P4 ============================================
echo 'edited' > "$DST/wm/kept.conf"          # user-editable: a conflict
echo 'base again' > "$BASE/sh/gone"           # a fresh orphan, base's
g "$TK" add -A; g "$TK" commit -m again
act place
g "$TK" rm -q "$BASE/sh/gone"; g "$TK" commit -m rm-again
act retire --dry-run "$DESK"
expect_rc 0 "retire --dry-run"
assert "dry run: says what it would retire" \
  has "$OUT" "would retire $DST/wm/wm.conf"
assert "dry run: removes nothing" test -f "$DST/wm/wm.conf"
act retire "$DESK"
expect_rc 0 "retire a layer"
assert "retired: its untouched file is removed" test ! -e "$DST/wm/wm.conf"
assert "retired: its record goes" test ! -e "$S/layer$DST/wm/wm.conf"
assert "retired: an edited user-editable file is LEFT" \
  test "$(cat "$DST/wm/kept.conf")" = edited
assert "retired: and named as a conflict" \
  has "$OUT" "left       $DST/wm/kept.conf"
assert "retired: the declared layer's orphan is NOT touched" \
  test -f "$DST/sh/gone"
assert "retired: the declared layer's file is untouched" test -f "$DST/sh/rc"
act retire "$TK/nope"
expect_rc 1 "retire: a layer nothing records"
assert "and says so" has "$ERR" "no placed file records the layer"
act retire "$BASE"
expect_rc 2 "retire: a DECLARED layer is refused"
assert "and says why" has "$ERR" "still a declared layer"

# === a repo-owned live edit is displaced before it is retired ===============
cfg_both
mkdir -p "$DESK/ro"
echo 'ro' > "$DESK/ro/ro.conf"
g "$TK" add -A; g "$TK" commit -m ro
printf 'policy %s repo-owned\n' "$DST/ro/ro.conf" >> "$MUSTER_CONFIG"
act place
echo 'live edit' > "$DST/ro/ro.conf"
grep -v "^place $DESK " "$MUSTER_CONFIG" > "$_T/cfg2"
mv "$_T/cfg2" "$MUSTER_CONFIG"
act retire "$DESK"
expect_rc 0 "retire with a repo-owned live edit"
assert "the edit is displaced first" has "$OUT" "displaced  $DST/ro/ro.conf"
assert "then the file is removed" test ! -e "$DST/ro/ro.conf"
assert "and the edit is kept" \
  test -n "$(find "$S/displaced" -path "*$DST/ro/ro.conf")"
act displaced clear --all

# === the ordering rule: unrecorded baselines, backfilled by place ===========
cfg_both
grep -v "^policy $DST/ro/" "$MUSTER_CONFIG" > "$_T/cfg2"
mv "$_T/cfg2" "$MUSTER_CONFIG"
rm -f "$DST/wm/kept.conf"
act place
expect_rc 0 "place, both layers again"
# Baselines placed before layers were recorded: no record at all.
find "$S/layer" -type f -exec rm -f {} +
act check
assert "check notes baselines with no layer recorded" \
  has "$OUT" "placed file(s) with no layer recorded"
act place
expect_rc 0 "place backfills"
assert "backfilled: the record is back" \
  test "$(rec "$DST/wm/wm.conf")" = "$DESK user-editable"
act check
assert "and the note is gone" lacks "$OUT" "no layer recorded"
# Unrecorded AND unsupplied: unknown cause, so unlayered, never an orphan.
rm -f "$S/layer$DST/wm/wm.conf"
g "$TK" rm -q "$DESK/wm/wm.conf"; g "$TK" commit -m rm-wm
pl
expv "$DST/wm/wm.conf" unlayered
act check
assert "check: an unrecorded layer says so" has "$OUT" "its layer is unrecorded"
act place
assert "unrecorded: nothing removed by place" test -f "$DST/wm/wm.conf"
act retire unrecorded
expect_rc 0 "retire unrecorded"
assert "retire unrecorded removes it" test ! -e "$DST/wm/wm.conf"

# === a destination root no longer declared at all: its baselines stray ======
mkdir -p "$TK/solo"
echo 'solo' > "$TK/solo/s.conf"
g "$TK" add -A; g "$TK" commit -m solo
printf 'place %s %s user-editable\n' "$TK/solo" "$HOME/solo" \
  >> "$MUSTER_CONFIG"
act place
assert "a solo root placed" test -f "$HOME/solo/s.conf"
grep -v "^place $TK/solo " "$MUSTER_CONFIG" > "$_T/cfg2"
mv "$_T/cfg2" "$MUSTER_CONFIG"
pl
expv "$HOME/solo/s.conf" unlayered
act place
assert "a stray is never removed by place" test -f "$HOME/solo/s.conf"
act retire "$TK/solo"
expect_rc 0 "retire the solo layer"
assert "the stray is removed by retire" test ! -e "$HOME/solo/s.conf"

# === capture: to the ONE layer holding the capture directory ================
echo 'app made' > "$DST/app/data/new.json"
pl
expv "$DST/app/data/new.json" capture
assert "capture: into the base layer" \
  has "$OUT" "source=$BASE/app/data/new.json"
act capture
assert "captured into the base layer's source" \
  test "$(cat "$BASE/app/data/new.json")" = 'app made'
assert "captured: the record names the base layer" \
  test "$(rec "$DST/app/data/new.json")" = "$BASE user-editable"
g "$TK" add -A; g "$TK" commit -m captured
mkdir -p "$DESK/app/data"
echo 'd' > "$DESK/app/data/d.json"
g "$TK" add -A; g "$TK" commit -m two-homes
act place
echo 'second' > "$DST/app/data/second.json"
pl
expv "$DST/app/data/second.json" unhomed
act capture
assert "unhomed: nothing captured" test ! -e "$BASE/app/data/second.json"
assert "unhomed: in neither layer" test ! -e "$DESK/app/data/second.json"
act check
expect_rc 3 "check: unhomed is a FAULT"
assert "check: says why" has "$OUT" "in no single layer's source"

# === every POSIX shell reads layers the same ================================
_base=$("$MUSTER" placed --porcelain 2>&1)
assert "parity: the base has rows" has "$_base" "path="
for _sh in dash bash ksh mksh zsh; do
  command -v "$_sh" >/dev/null 2>&1 || continue
  _o=$("$_sh" "$MUSTER" placed --porcelain 2>&1)
  assert "$_sh: the same layer records as sh" test "$_o" = "$_base"
done

h_verdict
