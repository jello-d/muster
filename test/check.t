#!/bin/sh
# test/check.t - `muster check`: profiles as policies over SETS of repos,
# expanded against the filesystem, and the incoherences it must name.
#
# Prints `ok   check (N checks)` or `FAIL check:` and every failure.
set -u

H_NAME=check
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

C=$_T/cfg
mkdir -p "$C"
for _n in alpha beta gamma hush hwdp; do mkrepo "$_n"; done
ck() {   # <config lines...>: write them, run check
  printf '%s\n' "$@" > "$C/repos"
  OUT=$(MUSTER_CONFIG=$C/repos "$MUSTER" check 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}
row() { printf '%s\n' "$OUT" | awk -v p="$1" '$1 == p'; }

# === a coherent policy =======================================================
ck 'profile watch owed 1h' 'profile canon catch-up 15m alpha' \
   'profile pkgs catch-up 2h /h.*/'
expect_rc 0 "disjoint acting profiles, overlapping observe-only"
assert "no selectors: the whole set" has "$(row watch)" "all (5)"
assert "a literal selects that repo" test "$(row canon | awk '{print $4}')" \
  = alpha
assert "a pattern selects by whole name" has "$(row pkgs)" "hush hwdp"
assert "a pattern is anchored: /h.*/ does not take alpha" \
  test -z "$(row pkgs | grep alpha)"
assert "coherent: no findings section" test -z "$(printf '%s\n' "$OUT" \
  | grep -E '^(overlap|missing|empty|unmatched) ')"

# === findings =================================================================
ck 'profile a catch-up 1h alpha beta' 'profile b catch-up 2h /b.*|gamma/'
expect_rc 1 "two acting profiles share a repo"
assert "overlap names both profiles and the repo" \
  has "$OUT" "overlap    a and b both act on beta"
ck 'profile a catch-up 1h' 'profile b catch-up 2h hush'
expect_rc 1 "a whole-set acting profile overlaps any other acting one"
assert "whole-set overlap named" has "$OUT" "a and b both act on hush"
ck 'profile a owed 1h alpha' 'profile b owed 2h alpha' \
   'profile c survey 1d alpha'
expect_rc 0 "observe-only profiles may overlap freely"
ck 'profile a catch-up 1h alpha' 'profile b owed 2h alpha'
expect_rc 0 "an acting and an observing profile may share a repo"

ck 'profile a owed 1h alpha nosuch'
expect_rc 1 "a literal that is not a repo here"
assert "missing named" has "$OUT" "missing    a: nosuch is not a repo here"
mkdir "$ROOT/plaindir"
ck 'profile a owed 1h plaindir'
expect_rc 1 "a literal naming a non-repo directory"

ck 'profile a owed 1h /zz.*/'
expect_rc 1 "a profile that selects nothing"
assert "empty named" has "$OUT" "empty      a: selects no repos"
assert "the dead pattern is noted too" \
  has "$OUT" "unmatched  a: /zz.*/ matches no repo here"

ck 'profile a owed 1h alpha /zz.*/'
expect_rc 0 "a pattern matching nothing beside a live selector: a note"
assert "unmatched is still shown" has "$OUT" "unmatched  a: /zz.*/"

if [ -n "$CAN_LOCK" ]; then
  mkrepo locked
  chmod 000 "$ROOT/locked"
  ck 'profile a owed 1h locked'
  expect_rc 0 "an unreadable literal is THERE, so not missing"
  chmod 755 "$ROOT/locked"
fi

# === selectors are validated as config =======================================
for _bad in 'profile a owed 1h //' 'profile a owed 1h /a[/' \
    'profile a owed 1h a/b' 'profile a owed 1h a,b'; do
  ck "$_bad"
  expect_rc 2 "an invalid selector: $_bad"
done
ck 'profile a owed 1h a.b-c_d /x|y/'
expect_rc 1 "valid selector syntax (findings, not a config error)"

cli() {
  OUT=$("$MUSTER" "$@" 2>"$_T/err" </dev/null)
  RC=$?
}
cli check extra
expect_rc 2 "check takes no arguments"

h_verdict
