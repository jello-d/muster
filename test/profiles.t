#!/bin/sh
# test/profiles.t - `muster run` and `muster report`: profiles, the run
# store, pruning, the lock, notify-on-change, and a report that says when
# a run is stale or never happened.
#
# Prints `ok   profiles (N checks)` or `FAIL profiles:` and every failure.
set -u

H_NAME=profiles
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"
# A stubbed systemctl: report asks systemd about driven profiles' timers,
# and a test must never read, let alone depend on, the real user manager.
h_stub_systemctl

export MUSTER_STATE_DIR="$_T/state"
C=$_T/cfg
mkdir -p "$C"
S=$MUSTER_STATE_DIR

cli() {
  OUT=$("$MUSTER" "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}
pfield() {   # <profile> <key>: from report --porcelain in OUT
  printf '%s\n' "$OUT" | awk -v p="profile=$1" '$1 == p' | tr ' ' '\n' \
    | sed -n "s/^$2=//p"
}
meta() { sed -n "s/^$2=//p" "$S/$1/latest.meta"; }
nhist() { find "$S/$1/history" -name '*.meta' | wc -l | tr -d ' '; }

# === the default profile, before and after its first run ===================
mkrepo one
# With nothing declared: owed over everything, ON DEMAND. Nothing is
# scheduled that was not declared, so not having run is not a finding.
cli report --porcelain
expect_rc 0 "report before any run, nothing declared"
assert "the default profile: named default, verb owed" \
  test "$(pfield default verb)" = owed
assert "default profile: on demand, no interval" \
  test "$(pfield default every)" = -
assert "default profile: driven by nothing" \
  test "$(pfield default driver)" = manual
assert "no run yet, on demand: on-demand" \
  test "$(pfield default status)" = on-demand
# Declaring only a driver gives the default profile a cadence.
printf 'driver systemd\n' > "$C/sys"
MUSTER_CONFIG=$C/sys cli report --porcelain
assert "driver systemd alone: the default runs hourly" \
  test "$(pfield default every)" = 1h
assert "driver systemd alone: a fresh intent is pending, not never" \
  test "$(pfield default status)" = pending

cli run default
expect_rc 0 "run: the verb's exit passes through (clean set)"
assert "run: records stored" test -s "$S/default/latest.records"
assert "run: stderr stored" test -f "$S/default/latest.err"
assert "run: meta has the verb" test "$(meta default verb)" = owed
assert "run: meta has the exit" test "$(meta default exit)" = 0
assert "run: meta has started and finished" \
  test "$(meta default finished)" -ge "$(meta default started)"
assert "run: one history entry" test "$(nhist default)" = 1
assert "run: no temp files left" \
  test -z "$(find "$S/default" -name '.run.*')"
assert "run: no lock left" test ! -e "$S/default/lock"
cli report --porcelain
expect_rc 0 "report after a clean run"
assert "after a clean run: ok" test "$(pfield default status)" = ok
assert "after a clean run: nothing needs attention" \
  test "$(pfield default attention)" = 0

# The store holds exactly what the verb prints: one computation.
_stored=$(cat "$S/default/latest.records")
_direct=$("$MUSTER" owed --porcelain --no-fetch 2>/dev/null)
assert "stored records equal the verb's own output" \
  test "$_stored" = "$_direct"

# === attention, and the report's own rows ===================================
upstream_moves one
cli run default
expect_rc 1 "run: attention passes through as 1"
cli report --porcelain
assert "report: attention" test "$(pfield default status)" = attention
assert "report: one row needs attention" test "$(pfield default attention)" = 1
cli report
assert "report table: the summary header" starts "$OUT" PROFILE
assert "report table: the profile's section" has "$OUT" "== default (owed)"
assert "report table: the row, by owed's own renderer" has "$OUT" "behind 1"
g "$ROOT/one" pull --ff-only

# === stale, failed, and a run older than it should be ======================
# Staleness is a promise only a DRIVEN profile makes.
MUSTER_CONFIG=$C/sys cli run default
sed -i.bak 's/^finished=.*/finished=1000/' "$S/default/latest.meta"
rm -f "$S/default/latest.meta.bak"
MUSTER_CONFIG=$C/sys cli report --porcelain
assert "a run older than twice its interval: stale" \
  test "$(pfield default status)" = stale
expect_rc 1 "report with a stale profile"
cli report --porcelain
assert "the same old run, undriven: not stale" \
  test "$(pfield default status)" = ok
MUSTER_ROOT=$_T/nowhere MUSTER_CONFIG=$C/sys "$MUSTER" run default \
  >/dev/null 2>&1
MUSTER_CONFIG=$C/sys cli report --porcelain
assert "a run that could not run: failed" \
  test "$(pfield default status)" = failed
assert "failed: exit 2 recorded" test "$(meta default exit)" = 2

# === declared profiles ======================================================
printf 'profile watch owed 30m\nprofile keep catch-up 2h\n' > "$C/two"
printf 'profile look survey 1d\n' >> "$C/two"
MUSTER_CONFIG=$C/two cli report --porcelain
assert "declared: three profiles, and no default" \
  test "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 3
assert "declared: watch every 30m" test "$(pfield watch every)" = 30m
assert "declared: the default is gone" test -z "$(pfield default verb)"
# A config whose LAST line is not a profile: the AND-list trap that once
# made every profile vanish under set -e.
printf 'profile tail owed 1h\nroot %s\n' "$ROOT" > "$C/tail"
MUSTER_CONFIG=$C/tail cli run tail
assert "profiles are found when the last line is not one" \
  test -s "$S/tail/latest.records"
MUSTER_CONFIG=$C/two cli run default
expect_rc 2 "running an undeclared profile"
assert "an undeclared profile is named" has "$ERR" "no profile 'default'"

for _bad in 'profile x frobnicate 1h' 'profile x owed 1w' 'profile x owed' \
    'profile x owed 1h bad/sel' 'profile a/b owed 1h' 'profile .x owed 1h' \
    'profile x owed h' 'profile x owed 10'; do
  printf '%s\n' "$_bad" > "$C/bad"
  MUSTER_CONFIG=$C/bad cli report
  expect_rc 2 "a bad profile line: $_bad"
done

# Per-profile choice of what runs unattended: a catch-up profile ACTS.
mkrepo acted
upstream_moves acted
MUSTER_CONFIG=$C/two cli run keep
assert "a catch-up profile pulls" \
  test "$(git -C "$ROOT/acted" rev-parse HEAD)" \
  = "$(git --git-dir="$_T/origins/acted.git" rev-parse main)"
assert "its stored records are catch-up's" \
  has "$(cat "$S/keep/latest.records")" "action=pull result=ok"
# ...and an owed profile does not.
upstream_moves acted
_before=$(git -C "$ROOT/acted" rev-parse HEAD)
MUSTER_CONFIG=$C/two cli run watch
assert "an owed profile changes nothing" \
  test "$(git -C "$ROOT/acted" rev-parse HEAD)" = "$_before"
MUSTER_CONFIG=$C/two cli run look
assert "a survey profile stores survey records" \
  has "$(cat "$S/look/latest.records")" "upstream_head="
g "$ROOT/acted" pull --ff-only

# === selection: a profile is a policy over SOME repos =======================
mkrepo selA
mkrepo selB
upstream_moves selA
upstream_moves selB
printf 'profile only catch-up 2h selA\nprofile pat owed 1h /sel.*/\n' \
  > "$C/sel"
MUSTER_CONFIG=$C/sel cli run only
assert "a selected repo is acted on" \
  test "$(git -C "$ROOT/selA" rev-parse HEAD)" \
  = "$(git --git-dir="$_T/origins/selA.git" rev-parse main)"
assert "an unselected repo is NOT" \
  test "$(git -C "$ROOT/selB" rev-parse HEAD)" \
  != "$(git --git-dir="$_T/origins/selB.git" rev-parse main)"
assert "the stored records cover only the selection" \
  test "$(wc -l < "$S/only/latest.records" | tr -d ' ')" = 1
MUSTER_CONFIG=$C/sel cli run pat
assert "a pattern selects by name" \
  test "$(awk '{print $1}' "$S/pat/latest.records" | tr '\n' ' ')" \
  = "name=selA name=selB "
g "$ROOT/selB" pull --ff-only

# An empty selection NEVER falls back to the whole set.
printf 'profile ghost catch-up 1h /nothing-here.*/\n' > "$C/ghost"
mkrepo bystander
upstream_moves bystander
_by=$(git -C "$ROOT/bystander" rev-parse HEAD)
MUSTER_CONFIG=$C/ghost cli run ghost
expect_rc 2 "a profile that selects nothing"
assert "an empty selection touched nothing" \
  test "$(git -C "$ROOT/bystander" rev-parse HEAD)" = "$_by"
assert "the failed run is stored, with its reason" \
  has "$(cat "$S/ghost/latest.err")" "selects no repos"
assert "and reported as failed" test "$(meta ghost exit)" = 2
g "$ROOT/bystander" pull --ff-only

# Overlapping ACTING profiles: run refuses, and the refusal is stored.
printf 'profile p1 catch-up 1h selA\nprofile p2 catch-up 2h /selA|selB/\n' \
  > "$C/over"
upstream_moves selA
_sa=$(git -C "$ROOT/selA" rev-parse HEAD)
MUSTER_CONFIG=$C/over cli run p1
expect_rc 2 "an acting profile that overlaps another"
assert "the overlap refusal touched nothing" \
  test "$(git -C "$ROOT/selA" rev-parse HEAD)" = "$_sa"
assert "the refusal names the overlap" \
  has "$(cat "$S/p1/latest.err")" "p1 p2 selA"
printf 'profile p1 catch-up 1h selA\nprofile p2 owed 2h /selA|selB/\n' \
  > "$C/over"
MUSTER_CONFIG=$C/over cli run p1
expect_rc 0 "overlapping an OBSERVE-only profile is fine"
g "$ROOT/selA" pull --ff-only 2>/dev/null

# === pruning ================================================================
printf 'profile p owed 1h\n' > "$C/p"
for _i in 1 2 3 4; do MUSTER_CONFIG=$C/p MUSTER_KEEP=2 cli run p; done
assert "pruned to MUSTER_KEEP" test "$(nhist p)" = 2
_newest=$(find "$S/p/history" -name '*.meta' | sort -n | tail -n 1)
assert "the newest run is kept, and is the latest" \
  cmp -s "$_newest" "$S/p/latest.meta"
# By AGE when no count is forced: 7 days unless the config says `keep`.
_hp=$S/p/history
_plant() {   # <epoch>: a stored run that started then
  for _x in records err meta; do : > "$_hp/$1-1.$_x"; done
}
_hour=$(( $(date +%s) - 3600 ))
_plant 1000
_plant "$_hour"
MUSTER_CONFIG=$C/p cli run p
assert "by age: a run from 1970 is pruned" test ! -e "$_hp/1000-1.meta"
assert "by age: one an hour old is kept (default 7 days)" \
  test -e "$_hp/$_hour-1.meta"
assert "by age: all three files of a pruned run go" \
  test ! -e "$_hp/1000-1.records" -a ! -e "$_hp/1000-1.err"
printf 'profile p owed 1h\nkeep 30m\n' > "$C/pk"
MUSTER_CONFIG=$C/pk cli run p
assert "keep 30m: the hour-old run is pruned too" \
  test ! -e "$_hp/$_hour-1.meta"
assert "keep 30m: this run is kept" test "$(nhist p)" -ge 1
for _bad in 'keep 1w' 'keep' 'keep 7d 8d'; do
  printf 'profile p owed 1h\n%s\n' "$_bad" > "$C/pb"
  MUSTER_CONFIG=$C/pb cli report
  expect_rc 2 "a bad keep line: $_bad"
done
printf 'keep 7d\nkeep 8d\n' > "$C/pb"
MUSTER_CONFIG=$C/pb cli report
expect_rc 2 "two keep lines"

# === the lock ===============================================================
# Held by a live process (this shell): refuse, change nothing.
mkdir "$S/p/lock"
echo $$ > "$S/p/lock/pid"
_m=$(cat "$S/p/latest.meta")
MUSTER_CONFIG=$C/p cli run p
expect_rc 2 "a profile already running"
assert "locked: says so" has "$ERR" "already running"
assert "locked: the store is untouched" \
  test "$(cat "$S/p/latest.meta")" = "$_m"
# Left by a dead process: taken over, and released after.
sh -c 'exit 0' &
_dead=$!
wait "$_dead"
echo "$_dead" > "$S/p/lock/pid"
MUSTER_CONFIG=$C/p cli run p
expect_rc 0 "a stale lock"
assert "stale lock: says it took over" has "$ERR" "stale lock"
assert "stale lock: released after" test ! -e "$S/p/lock"

# === one muster run at a time on a box ======================================
# Found live: two profiles' timers fired in the same second, and a
# catch-up pulled the canonical mid-way through an observer's run.
printf 'profile solo owed 1h\nrepo one\n' > "$C/solo"
BOX=$S/.box-lock
sleep 60 &
_holder=$!
mkdir "$BOX"
echo "$_holder" > "$BOX/pid"
_t0=$(date +%s)
MUSTER_CONFIG=$C/solo MUSTER_RUN_WAIT=2 cli run solo
_t1=$(date +%s)
expect_rc 2 "a box held past the wait: the run does not run"
assert "it waited, rather than giving up at once" \
  test $((_t1 - _t0)) -ge 2
assert "the run that did not run is stored, with its reason" \
  has "$(cat "$S/solo/latest.err")" "held this box"
assert "the holder's lock is untouched" \
  test "$(cat "$BOX/pid")" = "$_holder"
# The holder finishes while a run waits: the run proceeds.
( sleep 2; rm -f "$BOX/pid"; rmdir "$BOX" ) &
MUSTER_CONFIG=$C/solo MUSTER_RUN_WAIT=20 cli run solo
expect_rc 0 "a run that waited for the box, then ran"
assert "and released the box after" test ! -e "$BOX"
kill "$_holder" 2>/dev/null
wait "$_holder" 2>/dev/null
# A holder that died: its lock is taken over.
sh -c 'exit 0' &
_gone=$!
wait "$_gone"
mkdir "$BOX"
echo "$_gone" > "$BOX/pid"
# Bounded wait: if the takeover ever broke, this fails in seconds rather
# than hanging the suite for the default ten minutes.
MUSTER_CONFIG=$C/solo MUSTER_RUN_WAIT=5 cli run solo
expect_rc 0 "a dead holder's box lock"
assert "says it took over" has "$ERR" "stale box lock"
assert "and released it after" test ! -e "$BOX"

# === notify: the fleet's flag/clear protocol, as STATE =======================
# The stub speaks intervention-required's interface and logs each call.
N_LOG=$_T/notified
cat > "$_T/notifier" <<NOTIFIER
#!/bin/sh
case \$1 in flag|clear) ;; *) exit 9 ;; esac
printf '%s\n' "\$*" >> '$N_LOG'
NOTIFIER
chmod +x "$_T/notifier"
printf 'profile n owed 1h\nrepo one\nrepo nmoved\n' > "$C/n"
mkrepo nmoved
nrun() { MUSTER_CONFIG=$C/n MUSTER_NOTIFY=$_T/notifier cli run n; }
# nlast: the last PROFILE notification. Every run also flags or clears
# muster.config after its own, which nlast skips; nconfig reads that.
nlast() { grep -v ' muster\.config' "$N_LOG" 2>/dev/null | tail -n 1; }
nconfig() { grep ' muster\.config' "$N_LOG" 2>/dev/null | tail -n 1; }
nrun
assert "a clean run CLEARS its flag" test "$(nlast)" = "clear muster-n"
upstream_moves nmoved
nrun
assert "attention FLAGS, naming the profile, count and repos" \
  test "$(nlast)" = "flag muster-n muster n: 1 repo(s) need attention: nmoved"
nrun
assert "still needing attention: flagged again (idempotent state)" \
  starts "$(nlast)" "flag muster-n"
g "$ROOT/nmoved" pull --ff-only
nrun
assert "attention gone: cleared" test "$(nlast)" = "clear muster-n"
# A run that could not run is flagged as such. Profile p declares no
# repos, so a missing root stops its verb outright (exit 2).
MUSTER_ROOT=$_T/nowhere MUSTER_CONFIG=$C/p MUSTER_NOTIFY=$_T/notifier \
  "$MUSTER" run p >/dev/null 2>&1
assert "a run that could not run is flagged" \
  starts "$(nlast)" "flag muster-p muster p could not run (exit 2)"
# The notifier declared in the CONFIG, no environment: still reached.
printf 'profile n owed 1h\nrepo one\nrepo nmoved\nnotify %s\n' \
  "$_T/notifier" > "$C/ncfg"
(unset MUSTER_NOTIFY; MUSTER_CONFIG=$C/ncfg "$MUSTER" run n) >/dev/null 2>&1
assert "a config-declared notifier gets the run's state" \
  test "$(nlast)" = "clear muster-n"
# Configured but absent: said, never a silent no-op.
MUSTER_CONFIG=$C/n MUSTER_NOTIFY=no-such-notifier cli run n
assert "an absent notifier is reported" has "$ERR" "is not on PATH"
assert "an absent notifier does not lose the run" \
  test -s "$S/n/latest.records"
printf '#!/bin/sh\nexit 1\n' > "$_T/badnotifier"
chmod +x "$_T/badnotifier"
MUSTER_CONFIG=$C/n MUSTER_NOTIFY=$_T/badnotifier cli run n
assert "a failing notifier is reported" has "$ERR" "notifier"

# === report says when a stored run is out of date ===========================
# A stored run is what the timer SAW. When its repos move after it (a
# manual pull, a push, a commit), report names them, with the command
# that makes it current: found live, a manual catch-up worked and report
# stayed red, with nothing saying it was out of date.
mkrepo mv1
mkrepo mv2
printf 'profile mv owed 1h\nrepo mv1\nrepo mv2\n' > "$C/mv"
mvp() { MUSTER_CONFIG=$C/mv cli "$@"; }
mvp run mv
assert "a run stores the refs it left" test -s "$S/mv/latest.heads"
mvp report
expect_rc 0 "fresh run, nothing moved: report is clean"
assert "nothing moved: no footer" lacks "$OUT" "changed since"
mvp report --porcelain
assert "porcelain: moved=- when nothing moved" \
  test "$(pfield mv moved)" = -
echo more >> "$ROOT/mv1/f"
g "$ROOT/mv1" commit -am "a commit made by hand"
_st_before=$(find "$S" -type f | sort | xargs cksum 2>/dev/null)
mvp report
expect_rc 0 "a moved repo is a hint, not a failure"
assert "footer: names the profile and the repo" \
  has "$OUT" "mv: 1 repo(s) changed since its run (mv1)"
assert "footer: gives the refresh command" has "$OUT" "refresh: muster run mv"
assert "footer: points at resolve" has "$OUT" "muster resolve"
assert "footer: the unmoved repo is not named" lacks "$OUT" "mv2)"
assert "report wrote nothing into the store (read-only)" \
  test "$(find "$S" -type f | sort | xargs cksum 2>/dev/null)" = "$_st_before"
mvp report --porcelain
assert "porcelain: moved names the repo" test "$(pfield mv moved)" = mv1
# An upstream that moves counts too: a fetch is how a pull arrives.
upstream_moves mv2
g "$ROOT/mv2" fetch
mvp report --porcelain
assert "a fetched upstream counts as moved" \
  test "$(pfield mv moved)" = mv1,mv2
mvp run mv
mvp report
assert "after the refresh: no footer" lacks "$OUT" "changed since"
# A run that could not run stores no refs, so nothing is compared
# against an older run's.
mkdir "$S/.box-lock"
sleep 30 &
_mvh=$!
echo "$_mvh" > "$S/.box-lock/pid"
MUSTER_RUN_WAIT=1 mvp run mv
kill "$_mvh" 2>/dev/null
wait "$_mvh" 2>/dev/null
rm -f "$S/.box-lock/pid"
rmdir "$S/.box-lock"
assert "a run that did not run leaves no refs behind" \
  test ! -e "$S/mv/latest.heads"
mvp report --porcelain
assert "and reports nothing moved" test "$(pfield mv moved)" = -

# === config faults reach report and the banner ==============================
# A pending merge-back used to be seen only by `muster check`. Every run
# now stores the placement faults and flags muster.config; report reads
# the store. One real file, through its whole lifecycle.
CTK=$_T/ctk
mkdir -p "$CTK/conf" "$HOME/cdst"
echo 'one' > "$CTK/conf/a.conf"
git init -q "$CTK"
g "$CTK" add -A
g "$CTK" commit -m seed
printf 'profile c owed 1h\nrepo one\nplace %s %s user-editable\n' \
  "$CTK/conf" "$HOME/cdst" > "$C/c"
crun() { MUSTER_CONFIG=$C/c MUSTER_NOTIFY=$_T/notifier cli run c; }
crep() { MUSTER_CONFIG=$C/c cli report "$@"; }
MUSTER_CONFIG=$C/c "$MUSTER" place >/dev/null 2>&1
crun
assert "config clean: the store exists, empty" \
  test -e "$S/config.faults" -a ! -s "$S/config.faults"
assert "config clean: the banner is cleared" \
  test "$(nconfig)" = "clear muster.config"
crep
assert "config clean: no config section" lacks "$OUT" "config needs"
crep --porcelain
assert "porcelain: a config record, zero faults" \
  has "$OUT" "config=placement faults=0 asof="
echo 'my live edit' > "$HOME/cdst/a.conf"
crep
assert "before a run, report shows the STORED state" \
  lacks "$OUT" "config needs"
crun
assert "after a run: the fault is stored" \
  has "$(cat "$S/config.faults")" "merge-back $HOME/cdst/a.conf"
assert "after a run: the banner is flagged, with the count" \
  starts "$(nconfig)" "flag muster.config muster: 1 config fault(s)"
assert "the profile's own flag is separate" \
  test "$(nlast)" = "clear muster-c"
crep
expect_rc 1 "report with a config fault: 1"
assert "report: a config section, with its age" \
  has "$OUT" "== config needs a person (as of the last run,"
assert "report: names the file" has "$OUT" "merge-back $HOME/cdst/a.conf"
assert "report: and the command" has "$OUT" "muster resolve"
crep --porcelain
assert "porcelain: one fault" has "$OUT" "config=placement faults=1 "
OUT=$(MUSTER_CONFIG=$C/c "$MUSTER" check 2>&1)
assert "check words it the same: one classification" \
  has "$OUT" "$(cat "$S/config.faults")"
MUSTER_CONFIG=$C/c "$MUSTER" merge-back >/dev/null 2>&1
crun
assert "merged back: the store is empty again" test ! -s "$S/config.faults"
assert "merged back: the banner is cleared" \
  test "$(nconfig)" = "clear muster.config"
crep
assert "merged back: no config section" lacks "$OUT" "config needs"
# DRIFT IS NOT A FAULT: what an apply's `muster place` fixes on its own
# must never reach the banner. A new source file, not yet placed.
echo 'two' > "$CTK/conf/b.conf"
g "$CTK" add -A
g "$CTK" commit -m "a new file, not yet placed"
crun
assert "drift only: the store stays empty" test ! -s "$S/config.faults"
assert "drift only: the banner stays clear" \
  test "$(nconfig)" = "clear muster.config"
printf 'profile c owed 1h\nrepo one\n' > "$C/cn"
MUSTER_CONFIG=$C/cn MUSTER_NOTIFY=$_T/notifier cli run c
assert "no placement declared: no store at all" test ! -e "$S/config.faults"
MUSTER_CONFIG=$C/cn cli report --porcelain
assert "no placement declared: no config record" lacks "$OUT" "config="

# === unreachable is not attention, for a while ==============================
# A fetch that fails (the locked keyring at the greeter, measured by the
# integrator) leaves a row `unknown`. While the last GOOD fetch is fresh
# it does not raise the flag; once that is over a day old it does, so a
# key that stays broken is not hidden. Both verbs that fetch obey it.
mkrepo nunreach
g "$ROOT/nunreach" remote set-url origin "$_T/origins/no-such.git"
printf 'profile u owed 1h\nrepo nunreach\n' > "$C/u"
printf 'profile uc catch-up 1h\nrepo nunreach\n' > "$C/uc"
urun() { MUSTER_CONFIG=$C/$1 MUSTER_NOTIFY=$_T/notifier cli run "$1"; }
urun u
assert "unreachable, fetched recently: the row is still reported" \
  has "$(cat "$S/u/latest.records")" "fetch-failed"
assert "unreachable, fetched recently: owed does not flag" \
  test "$(nlast)" = "clear muster-u"
urun uc
assert "unreachable, fetched recently: catch-up does not flag" \
  test "$(nlast)" = "clear muster-uc"
for _u_f in FETCH_HEAD logs/refs/remotes/origin/main \
    logs/refs/remotes/origin/HEAD; do
  [ ! -e "$ROOT/nunreach/.git/$_u_f" ] \
    || touch -t 202001010000 "$ROOT/nunreach/.git/$_u_f"
done
urun u
assert "unreachable for over a day: owed flags it" \
  test "$(nlast)" = "flag muster-u muster u: 1 repo(s) need attention: nunreach"
urun uc
assert "unreachable for over a day: catch-up flags it" \
  starts "$(nlast)" "flag muster-uc muster uc: 1 repo(s)"
# Reachable again: a real verdict, judged as any other.
g "$ROOT/nunreach" remote set-url origin "$_T/origins/nunreach.git"
urun u
assert "reachable again: clean, cleared" test "$(nlast)" = "clear muster-u"

# === the command line =======================================================
cli run
expect_rc 2 "run with no profile"
cli run a b
expect_rc 2 "run with two profiles"
cli report --bogus
expect_rc 2 "report with an unknown option"

h_verdict
