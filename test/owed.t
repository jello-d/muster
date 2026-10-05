#!/bin/sh
# test/owed.t - `muster owed`, against real git repos: every rung of the
# catch-up ladder, the vendored-file verdicts, and a canonical that
# cannot be trusted.
#
# Prints `ok   owed (N checks)` or `FAIL owed:` and every failure.
set -u

H_NAME=owed
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

# owed [args...]: run it, porcelain, into OUT / ERR / RC
owed() {
  OUT=$("$MUSTER" owed --porcelain "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}

# === the ladder ==============================================================

mkrepo current
owed current
expect current owed nothing
expect current state ok
expect current overlap -
expect current artifacts -
expect_rc 0 "a repo owed nothing"

# owed fetches by default: the upstream moved and nobody fetched.
mkrepo behind
upstream_moves behind
owed --no-fetch behind
expect behind owed nothing
assert "--no-fetch: the stale verdict still carries its fetch time" \
  test "$(field behind fetched)" -gt 0
owed behind
expect behind owed pull
expect behind behind 1
expect_rc 1 "a repo owed a pull"

mkrepo ahead
commit_file "$ROOT/ahead" new "x" local
owed ahead
expect ahead owed push

# Dirty and behind: a pull would touch someone's work in progress.
mkrepo dirtybehind
upstream_moves dirtybehind
echo wip >> "$ROOT/dirtybehind/f"
owed dirtybehind
expect dirtybehind owed skip
expect dirtybehind state behind,dirty

# Dirty and ahead: a push does not touch the work tree, so it is owed.
mkrepo dirtyahead
commit_file "$ROOT/dirtyahead" new "x" local
echo wip > "$ROOT/dirtyahead/w"
owed dirtyahead
expect dirtyahead owed push

mkrepo dirtycurrent
echo wip > "$ROOT/dirtycurrent/w"
owed dirtycurrent
expect dirtycurrent owed nothing
expect dirtycurrent state dirty

# Diverged, the two sides touched different files: the vicus case.
mkrepo disjoint
upstream_moves disjoint
commit_file "$ROOT/disjoint" mine "x" local
owed disjoint
expect disjoint owed rebase,push
expect disjoint overlap -

# Diverged on the same file: touch nothing, and say which file.
mkrepo overlap
upstream_moves overlap
echo local >> "$ROOT/overlap/f"
g "$ROOT/overlap" commit -am local
owed overlap
expect overlap owed escalate
expect overlap overlap f

# A rename is BOTH paths, so a local rename of a file upstream edited is
# an overlap, not a disjoint change that a rebase could replay blind.
mkrepo renamed
upstream_moves renamed
g "$ROOT/renamed" mv f moved
g "$ROOT/renamed" commit -m rename
owed renamed
expect renamed owed escalate
expect renamed overlap f

# A local merge would be flattened by a rebase: escalate, whatever files.
mkrepo merged
upstream_moves merged
g "$ROOT/merged" checkout -b side
commit_file "$ROOT/merged" side "x" side
g "$ROOT/merged" checkout main
commit_file "$ROOT/merged" main2 "x" main2
g "$ROOT/merged" merge --no-ff -m merge side
owed merged
expect merged owed escalate
expect merged overlap -

# An overlapping path with a space stays one field.
mkrepo spaced
mkdir -p "$_T/other"
git clone -q "$_T/origins/spaced.git" "$_T/other/spaced" 2>/dev/null
commit_file "$_T/other/spaced" "a b" "theirs" theirs
g "$_T/other/spaced" push
commit_file "$ROOT/spaced" "a b" "mine" mine
owed spaced
expect spaced owed escalate
expect spaced overlap a%20b
assert "spaced: the record still has 11 fields" \
  test "$(rec spaced | awk '{print NF}')" -eq 11

# === what it could not establish is unknown, never a guess ===================

mkrepo nofetch
mkrepo fetchok
upstream_moves nofetch
upstream_moves fetchok
g "$ROOT/nofetch" remote set-url origin "$_T/origins/vanished.git"
owed nofetch fetchok
expect nofetch owed unknown
expect nofetch state fetch-failed
expect fetchok owed pull
assert "a failed fetch is named on stderr" has "$ERR" vanished

mkrepo noup
g "$ROOT/noup" checkout -b solo
owed noup
expect noup owed unknown
expect noup state no-upstream

mkrepo detached
g "$ROOT/detached" checkout --detach
owed detached
expect detached owed unknown

git init -q "$ROOT/unborn"
owed unborn
expect unborn owed unknown

owed nosuch
expect nosuch owed unknown
expect nosuch state absent

if [ -n "$CAN_LOCK" ]; then
  mkrepo locked
  chmod 000 "$ROOT/locked"
  owed locked
  expect locked owed unknown
  expect locked state unreadable
  chmod 755 "$ROOT/locked"
fi

# === expect: declared states owe nothing; a broken declaration is unknown ===
X=$_T/expect
mkdir -p "$X"
if [ -n "$CAN_LOCK" ]; then
  mkrepo sealed
  chmod 000 "$ROOT/sealed"
  printf 'expect sealed unreadable\n' > "$X/sealed"
  MUSTER_CONFIG=$X/sealed owed sealed
  expect sealed owed nothing
  expect sealed state unreadable
  expect_rc 0 "owed: a declared-unreadable repo"
  chmod 755 "$ROOT/sealed"
  MUSTER_CONFIG=$X/sealed owed sealed
  expect sealed owed unknown
  expect sealed state expect-mismatch
fi
printf 'expect nosuch unreadable\n' > "$X/wrong"
MUSTER_CONFIG=$X/wrong owed nosuch
expect nosuch owed unknown
assert "a suffixed terminal state raises no shell errors" test -z "$ERR"

# === the deployed clone ======================================================
C=$_T/cfg
mkdir -p "$C"
mkrepo pkg
git clone -q "$_T/origins/pkg.git" "$_T/deployed-pkg" 2>/dev/null
upstream_moves pkg
g "$ROOT/pkg" pull --ff-only
printf 'deployed pkg %s\n' "$_T/deployed-pkg" > "$C/dep"
MUSTER_CONFIG=$C/dep owed pkg
expect pkg owed redeploy

# === read-only: owed changes nothing it was not asked to fetch ==============
mkrepo ro
upstream_moves ro
echo wip > "$ROOT/ro/w"
touch "$ROOT/ro/f"
_head=$(git -C "$ROOT/ro" rev-parse HEAD)
_status=$(git -C "$ROOT/ro" status --porcelain)
sleep 1
touch "$_T/marker"
owed --no-fetch ro
assert "--no-fetch: nothing under .git changed" \
  test -z "$(find "$ROOT/ro/.git" -newer "$_T/marker")"
owed ro
expect ro owed skip
assert "owed: HEAD did not move" \
  test "$(git -C "$ROOT/ro" rev-parse HEAD)" = "$_head"
assert "owed: the work tree is exactly as it was" \
  test "$(git -C "$ROOT/ro" status --porcelain)" = "$_status"
assert "owed: no work-tree file was written" \
  test -z "$(find "$ROOT/ro" -path "$ROOT/ro/.git" -prune -o \
    -newer "$_T/marker" -print)"

# === vendored artifacts ======================================================
# A canonical repo, and a config naming the file and where repos carry it.
CANON_V1='# conventions, v1'
CANON_V2='# conventions, v2'
mkrepo notes
commit_file "$ROOT/notes" _conv "$CANON_V1" v1
g "$ROOT/notes" push
CANON=$ROOT/notes/_conv
printf 'artifact %s test/conv.t alt/conv.t\n' "$CANON" > "$C/art"
art() { MUSTER_CONFIG=$C/art owed "$@"; }

mkrepo vmatch
commit_file "$ROOT/vmatch" test/conv.t "$CANON_V1" seed
g "$ROOT/vmatch" push
art vmatch
expect vmatch artifacts test/conv.t:ok
expect vmatch owed nothing

mkrepo valt
commit_file "$ROOT/valt" alt/conv.t "$CANON_V1" seed
g "$ROOT/valt" push
art valt
expect valt artifacts alt/conv.t:ok

mkrepo vnone
art vnone
expect vnone artifacts -

# The canonical moves on (committed and pushed): every copy now differs.
commit_file "$ROOT/notes" _conv "$CANON_V2" v2
g "$ROOT/notes" push

# Origin does not carry v2 either: a re-seed is owed.
art vmatch
expect vmatch artifacts test/conv.t:reseed
expect vmatch owed reseed

# Origin ALREADY carries v2 (the other box re-seeded and pushed): pull,
# and do NOT re-seed, which would commit what the remote already has.
mkrepo vbehind
commit_file "$ROOT/vbehind" test/conv.t "$CANON_V1" seed
g "$ROOT/vbehind" push
git clone -q "$_T/origins/vbehind.git" "$_T/other/vbehind" 2>/dev/null
commit_file "$_T/other/vbehind" test/conv.t "$CANON_V2" reseed
g "$_T/other/vbehind" push
# Unfetched, the stale ref cannot see the other box's re-seed, so the
# verdict is reseed AND the record says how old its evidence is. Fetched,
# the verdict flips to pull. That flip is the reason owed fetches.
art --no-fetch vbehind
expect vbehind artifacts test/conv.t:reseed
art vbehind
expect vbehind artifacts test/conv.t:pull
expect vbehind owed pull

# Someone is editing the copy right now: leave it alone.
mkrepo vdirty
commit_file "$ROOT/vdirty" test/conv.t "$CANON_V1" seed
g "$ROOT/vdirty" push
echo '# in flight' >> "$ROOT/vdirty/test/conv.t"
art vdirty
expect vdirty artifacts test/conv.t:skip
expect vdirty owed skip

# A repo whose own state is unknown cannot have its copy judged.
mkrepo vgone
commit_file "$ROOT/vgone" test/conv.t "$CANON_V1" seed
g "$ROOT/vgone" push
g "$ROOT/vgone" remote set-url origin "$_T/origins/vgone-missing.git"
art vgone
expect vgone artifacts test/conv.t:unknown
expect vgone owed unknown

# --- requires: carrying a file is not always adopting it ---------------------
# A repo with a hook of its OWN at the vendored hook's path never adopted
# the vendored one; only a repo that carries the test has.
commit_file "$ROOT/notes" _hook "# vendored hook" hook
g "$ROOT/notes" push
printf 'artifact %s .githooks/pre-commit requires %s %s\n' \
  "$ROOT/notes/_hook" test/conv.t modules/tests/conv.t > "$C/req"
mkrepo ownhook
commit_file "$ROOT/ownhook" .githooks/pre-commit "# my own hook" own
g "$ROOT/ownhook" push
MUSTER_CONFIG=$C/req owed ownhook
expect ownhook artifacts -
expect ownhook owed nothing
mkrepo adopted
commit_file "$ROOT/adopted" .githooks/pre-commit "# vendored hook" hook
commit_file "$ROOT/adopted" modules/tests/conv.t "x" test
g "$ROOT/adopted" push
MUSTER_CONFIG=$C/req owed adopted
expect adopted artifacts .githooks/pre-commit:ok
commit_file "$ROOT/adopted" .githooks/pre-commit "# drifted" drift
g "$ROOT/adopted" push
MUSTER_CONFIG=$C/req owed adopted
expect adopted artifacts .githooks/pre-commit:reseed

# --- a canonical that cannot be trusted --------------------------------------
# Every way the canonical's checkout can be wrong makes its copies unknown.
canon_untrusted() {   # <description>: vmatch must read unknown
  art vmatch
  expect vmatch artifacts test/conv.t:unknown
  # The canonical's repo is NOT in this run, so no other row would say
  # anything: the copy's unknown must roll up and fail the run.
  expect vmatch owed unknown
  assert "$1: stderr says the canonical is not trusted" \
    has "$ERR" "canonical $CANON is"
}
echo '# local edit' >> "$CANON"
canon_untrusted "canonical dirty"
g "$ROOT/notes" checkout -- _conv

commit_file "$ROOT/notes" _conv "# v3, unpushed" v3
canon_untrusted "canonical ahead (unpushed)"
g "$ROOT/notes" reset --hard origin/main

git clone -q "$_T/origins/notes.git" "$_T/other/notes" 2>/dev/null
commit_file "$_T/other/notes" _conv "# v4, from the other box" v4
g "$_T/other/notes" push
canon_untrusted "canonical behind its origin"
# ONE PROBLEM, ONE ROW: with the canonical's repo IN the run, its own row
# owes the pull, and the copies say unknown without rolling it up (16
# rows reading unknown for one stale checkout, measured live 2026-10-01).
art notes vmatch
expect notes owed pull
expect vmatch artifacts test/conv.t:unknown
expect vmatch owed nothing
assert "one stale canonical, exactly one row needs attention" \
  test "$(printf '%s\n' "$OUT" | grep -vc 'owed=nothing')" = 1
assert "the warning still names the canonical" has "$ERR" "canonical $CANON"
g "$ROOT/notes" pull --ff-only

printf 'artifact %s/nope test/conv.t\n' "$ROOT/notes" > "$C/missing"
MUSTER_CONFIG=$C/missing owed vmatch
expect vmatch artifacts test/conv.t:unknown
expect vmatch owed unknown

# An unrelated dirty file in the canonical repo does not taint it.
echo scratch > "$ROOT/notes/scratch"
art vmatch
expect vmatch artifacts test/conv.t:reseed
assert "an unrelated dirty file: no warning" test -z "$ERR"

# === the command line, and one computation for both views ===================
cli() {
  OUT=$("$MUSTER" "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}
cli owed --bogus
expect_rc 2 "owed: an unknown option"
cli owed ''
expect_rc 2 "owed: an empty name"
cli owed current
expect_rc 0 "owed table, owed nothing"
assert "owed table: has a header" starts "$OUT" REPO
cli owed --no-fetch -- current
expect_rc 0 "owed: -- ends the options"
cli owed --no-fetch behind
assert "table WHY: the count, not the state word as well" \
  test "$(printf '%s\n' "$OUT" | awk '$1 == "behind" {
    sub(/^[^ ]+ +[^ ]+ +[^ ]+ +/, ""); print }')" = "behind 1"

set -- current behind ahead dirtybehind disjoint overlap noup nosuch
OUTP=$("$MUSTER" owed --porcelain --no-fetch "$@" 2>/dev/null); RCP=$?
OUTT=$("$MUSTER" owed --no-fetch "$@" 2>/dev/null); RCT=$?
assert "R10: same exit from both views" test "$RCP" = "$RCT"
assert "R10: one table row per record, plus the header" \
  test "$(printf '%s\n' "$OUTT" | wc -l)" \
  -eq "$(( $(printf '%s\n' "$OUTP" | wc -l) + 1 ))"
assert "R10: each record's owed list is on its table row" \
  test -z "$(printf '%s\n' "$OUTP" | while read -r _r; do
    _nm=$(printf '%s\n' "$_r" | tr ' ' '\n' | sed -n 's/^name=//p')
    _ow=$(printf '%s\n' "$_r" | tr ' ' '\n' | sed -n 's/^owed=//p')
    printf '%s\n' "$OUTT" | awk -v n="$_nm" -v o="$_ow" \
      '$1 == n && $2 == o { f = 1 } END { exit !f }' || echo "$_nm"
  done)"
KEYS='name owed state ahead behind fetched overlap artifacts'
KEYS="$KEYS reseed_since push_since path"
assert "every record carries every key, in order" \
  test -z "$(printf '%s\n' "$OUTP" | awk -v want="$KEYS" '{
    s = ""
    for (i = 1; i <= NF; i++) { k = $i; sub(/=.*/, "", k); s = s " " k }
    if (substr(s, 2) != want) print
  }')"
assert "no value is empty" \
  test -z "$(printf '%s\n' "$OUTP" | tr ' ' '\n' | grep '=$')"

# Same records, byte for byte, from every interpreter present.
BASE=$(MUSTER_CONFIG=$C/art sh "$MUSTER" owed --porcelain --no-fetch \
  "$@" vmatch vbehind 2>/dev/null)
for _sh in dash bash ksh mksh zsh; do
  command -v "$_sh" >/dev/null 2>&1 || continue
  _o=$(MUSTER_CONFIG=$C/art "$_sh" "$MUSTER" owed --porcelain --no-fetch \
    "$@" vmatch vbehind 2>&1)
  assert "$_sh: the same owed records as sh" test "$_o" = "$BASE"
done

# shellcheck source=SCRIPTDIR/../lib/survey_lib
. "$HERE/../lib/survey_lib"
# shellcheck source=SCRIPTDIR/../lib/owed_lib
. "$HERE/../lib/owed_lib"
printf 'garbage\n' | _ow_render porcelain >/dev/null 2>&1
assert "a malformed record fails the render" test "$?" = 1

# === a pending re-seed is ONE item, and not attention for its grace =======
# A canonical change makes every copy differ at once, on every box: as
# sixteen rows each, that was 48 alerts for one task. Now one item, and
# none until the change is older than `reseed-grace` (default 60m).
mkrepo rnotes
commit_file "$ROOT/rnotes" _rc "v1" canon
g "$ROOT/rnotes" push
for _r in rs1 rs2 rsmix; do
  mkrepo "$_r"
  commit_file "$ROOT/$_r" test/rc.t "v1" seed
  g "$ROOT/$_r" push
done
commit_file "$ROOT/rsmix" other "x" "unpushed work"
printf 'artifact %s test/rc.t\n' "$ROOT/rnotes/_rc" > "$C/rs"
rso() { OUT=$(MUSTER_CONFIG=$C/rs "$MUSTER" owed "$@" rnotes rs1 rs2 rsmix \
  2>"$_T/err" </dev/null); RC=$?; }
commit_file "$ROOT/rnotes" _rc "v2" "canonical, just now"
g "$ROOT/rnotes" push
rso --porcelain --no-fetch
expect rs1 owed reseed
expect rs1 reseed_since "$(git -C "$ROOT/rnotes" log -1 --format=%ct -- _rc)"
expect rsmix owed push,reseed
rso --no-fetch
assert "within the grace: one line for the re-seeds" \
  has "$OUT" "vendored-copies: 2 repo(s) await a re-seed"
assert "within the grace: no row for a re-seed-only repo" \
  test -z "$(printf '%s\n' "$OUT" | grep '^rs1 ')"
assert "a repo owing a re-seed AND a push keeps its own row" \
  has "$(printf '%s\n' "$OUT" | grep '^rsmix ')" "push,reseed"
# Past the grace: the canonical's change is two hours old.
printf 'v3\n' > "$ROOT/rnotes/_rc"
g "$ROOT/rnotes" add _rc
GIT_COMMITTER_DATE="@$(( $(date +%s) - 7200 )) +0000" \
  git -C "$ROOT/rnotes" commit -q -m "canonical, two hours ago"
g "$ROOT/rnotes" push
g "$ROOT/rsmix" push
rso --no-fetch
expect_rc 1 "past the grace: a re-seed is attention"
# rsmix's commit was pushed above, so it owes only the re-seed now: 3.
assert "past the grace: ONE item, with its count and age" \
  has "$OUT" "vendored-copies: 3 repo(s) carry a copy that differs"
assert "past the grace: says how old" has "$OUT" "changed 2h ago"
assert "past the grace: still no per-repo row" \
  test -z "$(printf '%s\n' "$OUT" | grep '^rs1 ')"
rso --porcelain --no-fetch
assert "porcelain keeps every record" \
  test "$(printf '%s\n' "$OUT" | grep -c 'owed=reseed ')" -ge 2
# Through a stored run: report counts ONE item, not one per repo.
printf 'artifact %s test/rc.t\nprofile rs owed 1h rnotes rs1 rs2\n' \
  "$ROOT/rnotes/_rc" > "$C/rsp"
MUSTER_CONFIG=$C/rsp "$MUSTER" run rs >/dev/null 2>&1
OUT=$(MUSTER_CONFIG=$C/rsp "$MUSTER" report --porcelain 2>/dev/null)
assert "report: ONE item needs attention, not two" \
  has "$OUT" "attention=1 "
# The same rule in catch-up's and sync's records (one renderer rule).
OUT=$(MUSTER_CONFIG=$C/rs "$MUSTER" sync rnotes rs1 rs2 2>/dev/null); RC=$?
expect_rc 1 "sync: a re-seed past the grace is attention there too"
assert "sync: ONE item" has "$OUT" "vendored-copies: 2 repo(s) carry"
assert "sync: no per-repo row" test -z "$(printf '%s\n' "$OUT" | grep '^rs1 ')"
# The grace is the integrator's to set.
printf 'artifact %s test/rc.t\nreseed-grace 3h\n' "$ROOT/rnotes/_rc" \
  > "$C/rs"
rso --no-fetch
expect_rc 0 "reseed-grace 3h: the two-hour-old change is not yet attention"
for _bad in 'reseed-grace 3w' 'reseed-grace' 'reseed-grace 1h 2h'; do
  printf '%s\n' "$_bad" > "$C/rsbad"
  OUT=$(MUSTER_CONFIG=$C/rsbad "$MUSTER" owed --no-fetch rs1 2>&1); RC=$?
  expect_rc 2 "a bad reseed-grace line: $_bad"
done

# === an unpushed commit waits out the push grace ==========================
# 27 of 32 "owes a push" episodes on one box settled within the hour, by
# the session that made the commit. So a push is attention only once its
# OLDEST unpushed commit is older than `push-grace` (default 60m).
mkrepo pfresh
commit_file "$ROOT/pfresh" w "x" "just now"
mkrepo pold
printf 'y\n' > "$ROOT/pold/w"
g "$ROOT/pold" add w
GIT_COMMITTER_DATE="@$(( $(date +%s) - 7200 )) +0000" \
  git -C "$ROOT/pold" commit -q -m "two hours ago"
OUT=$("$MUSTER" owed --porcelain --no-fetch pfresh pold 2>/dev/null)
expect pfresh owed push
expect pfresh push_since "$(git -C "$ROOT/pfresh" log -1 --format=%ct)"
OUT=$("$MUSTER" owed --no-fetch pfresh 2>/dev/null); RC=$?
expect_rc 0 "a fresh unpushed commit: not attention"
assert "...but shown, with how long" has "$OUT" "unpushed "
OUT=$("$MUSTER" owed --no-fetch pold 2>/dev/null); RC=$?
expect_rc 1 "an unpushed commit two hours old: attention"
printf 'push-grace 3h\n' > "$C/pg"
OUT=$(MUSTER_CONFIG=$C/pg "$MUSTER" owed --no-fetch pold 2>/dev/null); RC=$?
expect_rc 0 "push-grace 3h: two hours is not yet attention"
printf 'profile pp owed 1h pfresh\nprofile po owed 1h pold\n' > "$C/pp"
MUSTER_CONFIG=$C/pp "$MUSTER" run pp >/dev/null 2>&1
MUSTER_CONFIG=$C/pp "$MUSTER" run po >/dev/null 2>&1
OUT=$(MUSTER_CONFIG=$C/pp "$MUSTER" report --porcelain 2>/dev/null)
assert "a stored run: the fresh push is not attention" \
  has "$(printf '%s\n' "$OUT" | grep '^profile=pp ')" "attention=0 "
assert "a stored run: the old push is" \
  has "$(printf '%s\n' "$OUT" | grep '^profile=po ')" "attention=1 "
for _bad in 'push-grace 2w' 'push-grace' 'push-grace 1h 2h'; do
  printf '%s\n' "$_bad" > "$C/pgbad"
  OUT=$(MUSTER_CONFIG=$C/pgbad "$MUSTER" owed --no-fetch pold 2>&1); RC=$?
  expect_rc 2 "a bad push-grace line: $_bad"
done

h_verdict
