#!/bin/sh
# test/sync.t - `muster sync`, the unattended setting of the knob owed and
# catch-up are on, and `hold`, which keeps a repo out of every acting
# verb. Every refusal is produced for real: a process sitting inside a
# repo, a file saved since the last pull, a merge left open. Every check
# says what was done AND what was left alone.
#
# Prints `ok   sync (N checks)` or `FAIL sync:` and every failure.
set -u

H_NAME=sync
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

export MUSTER_STATE_DIR="$_T/state"
export MUSTER_CONFIG="$_T/cfg"
S=$_T/state
h_cfg "$MUSTER_CONFIG" </dev/null
sy() {   # [args...]: sync --porcelain, into OUT / ERR / RC
  OUT=$("$MUSTER" sync --porcelain "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}

# === the quiescent case: fast-forwarded ====================================
mkrepo quiet; upstream_moves quiet
sy quiet
expect quiet action pull
expect quiet result ok
expect quiet remaining nothing
assert "quiet: HEAD is origin's" \
  test "$(head_of "$ROOT/quiet")" = "$(origin_head quiet)"

# === never rebases ==========================================================
mkrepo div; upstream_moves div
commit_file "$ROOT/div" mine "local work" "a local commit"
_dv=$(head_of "$ROOT/div")
sy div
expect div action none
expect div result diverged
assert "diverged: HEAD untouched (catch-up WOULD rebase this)" \
  test "$(head_of "$ROOT/div")" = "$_dv"
assert "diverged: still owed, so still attention" \
  test "$(field div remaining)" = "rebase,push"
expect_rc 1 "a run that left something owed"

# === in use: a process of this user sits inside ============================
mkrepo used; upstream_moves used
mkdir -p "$ROOT/used/sub"
( cd "$ROOT/used/sub" && exec sleep 60 ) &
_sleeper=$!
_u_was=$(head_of "$ROOT/used")
sleep 1
sy used
expect used action none
expect used result in-use
assert "in-use NAMES its blocker" \
  starts "$(field used in_use_by)" "sleep:"
OUT=$("$MUSTER" sync used 2>/dev/null)
assert "...and the table shows it" has "$OUT" "in-use:sleep"
sy used
assert "in use (cwd in a SUBDIRECTORY): not pulled" \
  test "$(head_of "$ROOT/used")" = "$_u_was"
kill "$_sleeper" 2>/dev/null
wait "$_sleeper" 2>/dev/null
sy used
expect used result ok

# === a PARKED shell is not work; a shell running anything is ===============
# One idle prompt in a tmux pane kept a box's notes repo from ever being
# pulled. A shell waiting at a prompt is not hurt by a fast-forward; a
# running program is, and a shell counts the moment it runs one.
mkrepo parked; upstream_moves parked
sleep 60 | ( cd "$ROOT/parked" && exec sh -c 'read _x' ) &
_parked=$!
sleep 1
assert "the parked shell really sits inside the repo" \
  test "$(readlink "/proc/$_parked/cwd")" = "$ROOT/parked"
sy parked
expect parked result ok
assert "a parked shell inside: pulled anyway" \
  test "$(head_of "$ROOT/parked")" = "$(origin_head parked)"
kill "$_parked" 2>/dev/null
wait "$_parked" 2>/dev/null
# A shell running a child counts, even when the CHILD is elsewhere: it
# is the shell being busy that matters, not where its child sits.
mkrepo working; upstream_moves working
( cd "$ROOT/working" && exec sh -c '(cd / && exec sleep 60); :' ) \
  2>/dev/null &
_work=$!
sleep 1
_w_was=$(head_of "$ROOT/working")
sy working
expect working result in-use
assert "a shell running something inside: not pulled" \
  test "$(head_of "$ROOT/working")" = "$_w_was"
pkill -P "$_work" 2>/dev/null
kill "$_work" 2>/dev/null
wait "$_work" 2>/dev/null

# === the blocker named is the PROGRAM, not the shell running it ============
mkrepo prog; upstream_moves prog
# stderr away: the shell reports its child's kill, as noise in the run.
( cd "$ROOT/prog" && exec sh -c 'sleep 60; :' ) 2>/dev/null &
_prog=$!
sleep 1
sy prog
assert "a shell and its program both inside: the program is named" \
  starts "$(field prog in_use_by)" "sleep:"
pkill -P "$_prog" 2>/dev/null
kill "$_prog" 2>/dev/null
wait "$_prog" 2>/dev/null

# === a repo whose name extends another's is not "inside" it =================
mkrepo near; upstream_moves near
mkdir -p "$ROOT/near-other"
( cd "$ROOT/near-other" && exec sleep 60 ) &
_sleeper=$!
sleep 1
sy near
assert "a process in near-other does not make near in use" \
  test "$(field near result)" = ok
kill "$_sleeper" 2>/dev/null
wait "$_sleeper" 2>/dev/null

# === touched: saved since HEAD last moved, content unchanged ================
mkrepo touched; upstream_moves touched
_t_was=$(head_of "$ROOT/touched")
sleep 1
touch "$ROOT/touched/f"
# Lock-free, as muster reads: a PLAIN status re-caches the index, which
# is what hides a touch from a git-aware prompt (and from this test).
assert "touched: the tree is CLEAN (catch-up would pull it)" \
  test -z "$(GIT_OPTIONAL_LOCKS=0 git -c diff.autoRefreshIndex=false \
    -C "$ROOT/touched" status --porcelain)"
sy touched
expect touched action none
expect touched result touched
assert "touched: not pulled" \
  test "$(head_of "$ROOT/touched")" = "$_t_was"
# An IGNORED file is not the tree: a build product changing is no reason.
mkrepo ign
printf 'out/\n' > "$ROOT/ign/.gitignore"
g "$ROOT/ign" add .gitignore
g "$ROOT/ign" commit -m ignore
g "$ROOT/ign" push
upstream_moves ign
g "$ROOT/ign" fetch
sleep 1
mkdir -p "$ROOT/ign/out"
echo built > "$ROOT/ign/out/x"
sy ign
expect ign result ok

# === a FRESH CLONE is not touched ==========================================
# git writes a clone's reflog BEFORE its checkout, so its files are all
# newer than the reflog: read against that, every fresh clone was
# `touched` and never pulled (live on a new box: sixteen repos, hours).
mkrepo cloned
git clone -q "$_T/origins/cloned.git" "$ROOT/fresh" 2>/dev/null
upstream_moves cloned
g "$ROOT/fresh" fetch
sy fresh
expect fresh action pull
expect fresh result ok

# === busy: a git operation left open =======================================
mkrepo busy; upstream_moves busy
git -C "$ROOT/busy" rev-parse HEAD > "$ROOT/busy/.git/MERGE_HEAD"
_b_was=$(head_of "$ROOT/busy")
sy busy
expect busy result busy
assert "busy: not pulled" test "$(head_of "$ROOT/busy")" = "$_b_was"
rm -f "$ROOT/busy/.git/MERGE_HEAD"

# === dirty: skipped, never touched (as catch-up) ===========================
mkrepo dirty; upstream_moves dirty
echo 'in progress' >> "$ROOT/dirty/f"
sy dirty
expect dirty action none
expect dirty remaining skip
assert "dirty: the work survives" \
  test "$(tail -n 1 "$ROOT/dirty/f")" = "in progress"

# === the invoker's own shell is not "a session inside" ======================
mkrepo self; upstream_moves self
# `; true` keeps the invoking shell ALIVE inside the repo: without it a
# shell may exec muster directly, and there is no parent to exclude (the
# first version of this test passed with the exclusion removed).
OUT=$(sh -c 'cd "$1" && "$2" sync --porcelain self; true' sh \
  "$ROOT/self" "$MUSTER" 2>&1 </dev/null)
expect self result ok
# ...and a shell inside the repo that did NOT invoke it still counts.
mkrepo other; upstream_moves other
( cd "$ROOT/other" && exec sleep 60 ) &
_sleeper=$!
sleep 1
OUT=$(sh -c 'cd "$1" && "$2" sync --porcelain other; true' sh \
  "$ROOT/self" "$MUSTER" 2>&1 </dev/null)
expect other result in-use
kill "$_sleeper" 2>/dev/null
wait "$_sleeper" 2>/dev/null

# === dry run: says what it would do, and why not, moving nothing ============
mkrepo dry; upstream_moves dry
_d_was=$(head_of "$ROOT/dry")
mkrepo drybusy; upstream_moves drybusy
git -C "$ROOT/drybusy" rev-parse HEAD > "$ROOT/drybusy/.git/MERGE_HEAD"
sy --dry-run dry drybusy
expect dry result dry-run
expect drybusy result busy
assert "dry-run: nothing moved" test "$(head_of "$ROOT/dry")" = "$_d_was"
rm -f "$ROOT/drybusy/.git/MERGE_HEAD"

# === the canonical goes first, under the same rules =========================
mkrepo canon
commit_file "$ROOT/canon" art.t "v1" "canonical v1"
g "$ROOT/canon" push
mkrepo user
mkdir -p "$ROOT/user/t"
cp "$ROOT/canon/art.t" "$ROOT/user/t/art.t"
g "$ROOT/user" add t/art.t
g "$ROOT/user" commit -m vendored
g "$ROOT/user" push
printf 'artifact %s t/art.t\n' "$ROOT/canon/art.t" | h_cfg "$MUSTER_CONFIG"
upstream_moves canon
( cd "$ROOT/canon" && exec sleep 60 ) &
_sleeper=$!
_c_was=$(head_of "$ROOT/canon")
sleep 1
sy canon user
assert "an IN-USE canonical is not pulled, even first" \
  test "$(head_of "$ROOT/canon")" = "$_c_was"
expect canon result in-use
kill "$_sleeper" 2>/dev/null
wait "$_sleeper" 2>/dev/null
sy canon user
expect canon result ok
h_cfg "$MUSTER_CONFIG" </dev/null

# === hold: observed by every verb, moved by none ============================
mkrepo held; upstream_moves held
_h_was=$(head_of "$ROOT/held")
printf 'hold held\n' | h_cfg "$MUSTER_CONFIG"
OUT=$("$MUSTER" owed --porcelain held 2>/dev/null); RC=$?
expect held owed held
expect_rc 0 "owed: a held repo alone is not attention"
sy held
expect held remaining held
assert "sync: never moves a held repo" \
  test "$(head_of "$ROOT/held")" = "$_h_was"
expect_rc 0 "sync: held is not attention"
"$MUSTER" catch-up held >/dev/null 2>&1
assert "catch-up: never moves a held repo" \
  test "$(head_of "$ROOT/held")" = "$_h_was"
OUT=$("$MUSTER" resolve held 2>&1 </dev/null); RC=$?
assert "resolve: never moves a held repo" \
  test "$(head_of "$ROOT/held")" = "$_h_was"
assert "resolve: a held repo is not on the list" \
  has "$OUT" "== nothing needs you"
# Held hides no problem: unpushed work is still owed a push...
mkrepo heldahead
commit_file "$ROOT/heldahead" mine "x" "unpushed while held"
printf 'hold /held.*/\n' | h_cfg "$MUSTER_CONFIG"
OUT=$("$MUSTER" owed --porcelain heldahead 2>/dev/null)
expect heldahead owed push
# ...and a /regex/ hold matches in full, or not at all.
mkrepo unheld; upstream_moves unheld
OUT=$("$MUSTER" owed --porcelain unheld 2>/dev/null)
expect unheld owed pull
OUT=$("$MUSTER" check 2>&1)
assert "check: a hold that matches nothing is a note" lacks "$OUT" \
  "hold       /held.*/"
printf 'hold no-such-repo\n' | h_cfg "$MUSTER_CONFIG"
OUT=$("$MUSTER" check 2>&1)
assert "check: a literal hold naming no repo here is a note" \
  has "$OUT" "note   hold       no-such-repo matches no repo here"
printf 'hold bad/name\n' | h_cfg "$MUSTER_CONFIG"
OUT=$("$MUSTER" owed --porcelain held 2>&1); RC=$?
expect_rc 2 "an invalid hold selector: the config is refused"
h_cfg "$MUSTER_CONFIG" </dev/null

# === sync as a profile verb ==================================================
mkrepo prof; upstream_moves prof
printf 'profile s sync 15m prof\n' | h_cfg "$MUSTER_CONFIG"
OUT=$("$MUSTER" run s 2>&1); RC=$?
expect_rc 0 "run s: a sync profile"
assert "the profile pulled" \
  test "$(head_of "$ROOT/prof")" = "$(origin_head prof)"
assert "and stored its records" has "$(cat "$S/s/latest.records")" \
  "name=prof action=pull result=ok"
printf 'profile s sync 15m prof\nprofile c catch-up 15m prof\n' \
  | h_cfg "$MUSTER_CONFIG"
OUT=$("$MUSTER" check 2>&1); RC=$?
assert "sync ACTS: overlapping a catch-up profile is a fault" \
  has "$OUT" "overlap    s and c both act on prof"
h_cfg "$MUSTER_CONFIG" </dev/null

sy --bogus
expect_rc 2 "an unknown option"
assert "named as sync's" has "$ERR" "muster sync: unknown option"

# === an IDLE holder does not hold a repo (M1, 2026-10-29) ==================
# Four agent sessions restored at boot and never used held their repos for
# a day. A holder with NO children whose TERMINAL has been quiet for
# idle-after (1h) no longer declines the pull; it is named in the record.
# A real pty from script(1), its times set back by hand.
assert "script(1) is here to give a holder a terminal" \
  test -n "$(command -v script)"
hold() {   # <dir> <command>: run <command> in <dir> on a pty; PID set
  _h_pf=$_T/holder.pid
  rm -f "$_h_pf"
  ( cd "$_T" && exec script -qfc \
    "cd '$1' && echo \$\$ > '$_h_pf' && exec $2" /dev/null \
    </dev/null >/dev/null 2>&1 ) &
  _h_n=0
  while [ ! -s "$_h_pf" ] && [ "$_h_n" -lt 50 ]; do
    sleep 0.1; _h_n=$((_h_n + 1)); done
  PID=$(cat "$_h_pf")
  sleep 0.3
}
age() { touch -d "$2 ago" "$(readlink "/proc/$1/fd/0")"; }   # <pid> <age>
unhold() { kill "$1" 2>/dev/null; sleep 0.2; }

mkrepo idler; upstream_moves idler
hold "$ROOT/idler" 'sleep 300'
assert "the holder has a terminal" \
  has "$(readlink "/proc/$PID/fd/0")" /dev/pts/
sy idler
expect idler result in-use
assert "a terminal active just now: in-use, as before" \
  starts "$(field idler in_use_by)" "sleep:$PID"
age "$PID" '2 hours'
sy idler
expect idler result ok
assert "quiet two hours, no children: pulled" \
  test "$(head_of "$ROOT/idler")" = "$(origin_head idler)"
assert "the record names the idle holder" \
  starts "$(field idler idle_by)" "sleep:$PID:"
assert "...and how long it was quiet" \
  test "$(field idler idle_by | cut -d: -f3)" -ge 7000
assert "an idle holder is not in_use_by" test "$(field idler in_use_by)" = -
upstream_moves idler
OUT=$("$MUSTER" sync idler 2>/dev/null)
assert "the table says so" has "$OUT" "ok (idle sleep 2h)"
assert "and retro tallies it" \
  has "$(cat "$S"/retro/tally/* 2>/dev/null)" "pulled-under-idle:sleep idler"
unhold "$PID"

# THE LIVE SHAPE: a shell (inside the repo) that launched the idle
# program. Its child is idle, so it is a parked shell in all but name;
# found live, where every idle agent's own shell still held its repo.
mkrepo launched; upstream_moves launched
hold "$ROOT/launched" "sh -c 'sleep 300; :'"
age "$PID" '2 hours'
sy launched
expect launched result ok
assert "a shell whose child is idle: pulled, and the PROGRAM is named" \
  starts "$(field launched idle_by)" "sleep:"
pkill -P "$PID" 2>/dev/null; unhold "$PID"

# A shell is idle only if what it runs is: here its child (a program
# with a child of its own) has moved OUTSIDE the repo, so only the shell
# holds it, and only by what it is running.
mkrepo farkid; upstream_moves farkid
hold "$ROOT/farkid" "sh -c '(cd / && exec timeout 300 sleep 300); :'"
age "$PID" '2 hours'
_fk=$(head_of "$ROOT/farkid")
sy farkid
expect farkid result in-use
assert "a shell whose child is LIVE, even elsewhere: in-use" \
  test "$(head_of "$ROOT/farkid")" = "$_fk"
pkill -P "$PID" 2>/dev/null; unhold "$PID"

# A program with a child is running something, however quietly (an
# agent running a silent build): it holds, whatever its terminal says.
mkrepo busyidle; upstream_moves busyidle
hold "$ROOT/busyidle" 'timeout 300 sleep 300'
age "$PID" '2 hours'
_bi=$(head_of "$ROOT/busyidle")
sy busyidle
expect busyidle result in-use
assert "quiet terminal but a program with a CHILD: in-use" \
  test "$(head_of "$ROOT/busyidle")" = "$_bi"
assert "...named" starts "$(field busyidle in_use_by)" "timeout:"
pkill -P "$PID" 2>/dev/null; unhold "$PID"

# touched still wins over an idle holder: it is what an edit leaves.
mkrepo idletouched; upstream_moves idletouched
sleep 1
touch "$ROOT/idletouched/f"   # a tracked file saved since HEAD moved
hold "$ROOT/idletouched" 'sleep 300'
age "$PID" '2 hours'
sy idletouched
expect idletouched result touched
unhold "$PID"

# The setting.
mkrepo idlelong; upstream_moves idlelong
printf 'idle-after 3h\n' | h_cfg "$MUSTER_CONFIG"
hold "$ROOT/idlelong" 'sleep 300'
age "$PID" '2 hours'
sy idlelong
expect idlelong result in-use
unhold "$PID"
h_cfg "$MUSTER_CONFIG" </dev/null
printf 'idle-after 1h\nidle-after 2h\n' | h_cfg "$_T/ia2"
OUT=$(MUSTER_CONFIG=$_T/ia2 "$MUSTER" sync idlelong 2>&1); RC=$?
expect_rc 2 "idle-after twice: a config error"

h_verdict
