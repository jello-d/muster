#!/bin/sh
# test/retro.t - `muster retro`, the long view: every event kind declared
# in the one table (and the table holding nothing the code cannot emit),
# events written by the verb that acted, episodes opened and settled by
# runs, weekly files pruned by name, and the readers.
#
# Prints `ok   retro (N checks)` or `FAIL retro:` and every failure.
set -u

H_NAME=retro
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

export MUSTER_STATE_DIR="$_T/state"
export MUSTER_CONFIG="$_T/cfg"
S=$_T/state
R=$S/retro
: > "$MUSTER_CONFIG"
cli() {
  OUT=$("$MUSTER" "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}
ev() { cat "$R"/events/* 2>/dev/null; }   # every event line
tl() { cat "$R"/tally/* 2>/dev/null; }    # every tally line
evk() {   # <kind> <where>: that event's lines
  ev | awk -v k="kind=$1" -v w="where=$2" '$3 == k && $5 == w'
}

# === the table: what the code can emit is declared, and nothing more =======
LIB=$HERE/../lib
_emitted=$(grep -ho 'retro_event [a-z][a-z-]*' "$LIB"/*_lib \
  | awk '{ print $2 }' | sort -u)
_declared=$(sed -n "/^RT_KINDS='/,/'$/p" "$LIB/retro_lib" \
  | sed "s/^RT_KINDS='//; s/'$//" | awk '{ print $2 }' | sort -u)
assert "the table parses" test -n "$_declared"
assert "every kind the code emits is declared (missing: $(printf \
'%s\n' "$_emitted" | grep -vxF "$_declared" | tr '\n' ' '))" \
  test -z "$(printf '%s\n' "$_emitted" | grep -vxF "$_declared")"
# needed-you, settled and the catch-up outcomes are emitted through a
# variable or a mapped case, so they are listed here by hand, once.
_via_case='pulled rebased reverted rebase-aborted abort-failed
revert-failed changed-underfoot pull-failed unseen needed-you settled'
_dead=$(printf '%s\n' "$_declared" | while read -r _k; do
  printf '%s\n' "$_emitted" | grep -qxF "$_k" && continue
  case " $(printf '%s' "$_via_case" | tr '\n' ' ') " in
    *" $_k "*) continue ;;
  esac
  printf '%s ' "$_k"
done)
assert "no declared kind is dead (dead: $_dead)" test -z "$_dead"

# === sync records what it did, and what it declined, by the verb ===========
mkrepo pulled; upstream_moves pulled
mkrepo busy; upstream_moves busy
( cd "$ROOT/busy" && exec sleep 60 ) &
_sleeper=$!
sleep 1
cli sync --dry-run pulled busy
assert "a dry run records nothing" test -z "$(ev)$(tl)"
cli sync pulled busy
kill "$_sleeper" 2>/dev/null
wait "$_sleeper" 2>/dev/null
assert "a pull is an action event" \
  has "$(evk pulled pulled)" "class=action kind=pulled origin=manual"
assert "with its from..to" has "$(evk pulled pulled)" "detail="
assert "a decline is a TALLY, not an event" \
  has "$(tl)" "declined:in-use busy 1"
assert "and not an event" test -z "$(evk in-use busy)"
assert "WHO held it is tallied, for the review" \
  has "$(tl)" "in-use-by:sleep busy 1"

# === a run: the profile is the origin, and the run is tallied ==============
upstream_moves pulled
printf 'profile fl sync 15m pulled\n' > "$MUSTER_CONFIG"
cli run fl
assert "a run's pull carries the PROFILE as its origin" \
  has "$(evk pulled pulled)" "origin=fl"
assert "the pull is recorded once, by the verb, not again by the run" \
  test "$(evk pulled pulled | grep -c 'origin=fl')" = 1
assert "the run is tallied" has "$(tl)" "run:ok fl 1"

# === episodes: began once, settled once, with how long =====================
mkrepo ahead
# Two hours old: a FRESH unpushed commit waits out the push grace and
# opens no episode, which is the rule; this one is due.
printf 'x\n' > "$ROOT/ahead/a"
g "$ROOT/ahead" add a
GIT_COMMITTER_DATE="@$(( $(date +%s) - 7200 )) +0000" \
  git -C "$ROOT/ahead" commit -q -m "unpushed, two hours ago"
printf 'profile w owed 1h ahead\n' > "$MUSTER_CONFIG"
rm -f "$R/open"
: > "$R/open"
cli run w
assert "the FIRST episode, into an EMPTY open file, is well formed" \
  test "$(awk 'NF != 4' "$R/open")" = ""
assert "...and is the episode, nothing else" \
  test "$(awk '{ print $1, $2 }' "$R/open")" = "w ahead"
assert "needing you: an episode begins" \
  has "$(evk needed-you ahead)" "class=episode kind=needed-you origin=w"
assert "with the verdict" has "$(evk needed-you ahead)" "detail=push"
assert "and is open" has "$(cat "$R/open")" "w ahead "
cli run w
assert "still needing you: no second episode" \
  test "$(evk needed-you ahead | wc -l | tr -d ' ')" = 1
g "$ROOT/ahead" push
cli run w
assert "settled, with how long it lasted" \
  has "$(evk settled ahead)" "kind=settled origin=w where=ahead detail=push"
assert "and a duration" has "$(evk settled ahead)" " dur="
assert "and it is no longer open" lacks "$(cat "$R/open")" "w ahead "

# === a run that could not run: an unusual event, episodes untouched ========
# No selection and no root: the verb itself cannot run (exit 2). A NAMED
# repo under a missing root is a valid run that reads it `unknown`.
printf 'profile nr owed 1h\n' > "$MUSTER_CONFIG"
cli run nr
assert "nr has an episode open (a repo behind needs a pull)" \
  has "$(cat "$R/open")" "nr busy "
cp "$R/open" "$_T/open.before"
MUSTER_ROOT=$_T/nowhere cli run nr
expect_rc 2 "the run could not run"
assert "a run that could not run is unusual" \
  has "$(evk could-not-run nr)" "class=unusual kind=could-not-run"
assert "it touched no episode" cmp -s "$R/open" "$_T/open.before"
assert "and is tallied as failed" has "$(tl)" "run:failed nr 1"
printf 'profile w owed 1h ahead\n' > "$MUSTER_CONFIG"

# === push: pushed, and a refused push ======================================
mkrepo pu
commit_file "$ROOT/pu" a "p" "to push"
cli push pu
assert "a push is an action" has "$(evk pushed pu)" "class=action"
mkrepo refused
commit_file "$ROOT/refused" a "r" "refused"
printf '#!/bin/sh\nexit 1\n' > "$ROOT/refused/.git/hooks/pre-push"
chmod +x "$ROOT/refused/.git/hooks/pre-push"
cli push refused
assert "a failed push is unusual, with why" \
  has "$(evk push-failed refused)" "class=unusual kind=push-failed"

# === config: merge-back as an action, a live edit as an episode ============
CT=$_T/ct
mkdir -p "$CT/c" "$HOME/cd"
echo one > "$CT/c/a.conf"
git init -q "$CT"; g "$CT" add -A; g "$CT" commit -m seed
printf 'profile w owed 1h ahead\nplace %s %s user-editable\n' \
  "$CT/c" "$HOME/cd" > "$MUSTER_CONFIG"
cli place
echo 'live edit' > "$HOME/cd/a.conf"
cli run w
assert "a pending merge-back opens a CONFIG episode" \
  has "$(evk needed-you "$HOME/cd/a.conf")" "origin=config"
assert "with its kind" has "$(evk needed-you "$HOME/cd/a.conf")" \
  "detail=merge-back"
cli merge-back
assert "merging back is an action" \
  has "$(evk merged-back "$HOME/cd/a.conf")" "class=action"
cli run w
assert "and the config episode settles" \
  has "$(evk settled "$HOME/cd/a.conf")" "origin=config"

# === lock takeover and a failing notifier are unusual ======================
mkdir -p "$S/w/lock"
sh -c 'exit 0' &
_dead=$!
wait "$_dead"
echo "$_dead" > "$S/w/lock/pid"
cli run w
assert "a stale lock taken over is unusual" \
  has "$(evk lock-taken-over w)" "class=unusual"
printf '#!/bin/sh\nexit 1\n' > "$_T/badnotify"
chmod +x "$_T/badnotify"
MUSTER_NOTIFY=$_T/badnotify cli run w
assert "a failing notifier is unusual" \
  has "$(ev | grep 'kind=notifier-failed')" "class=unusual"

# === pruning: a week older than a year goes whole, by name =================
echo 't=1000 class=action kind=pulled origin=x where=old detail=-' \
  > "$R/events/2020-W01"
echo 'declined:in-use old 5' > "$R/tally/2020-W01"
_now_wk=$(find "$R/events" -type f | sed 's|.*/||' | sort | tail -n 1)
cli run w
assert "an events week from 2020 is pruned" test ! -e "$R/events/2020-W01"
assert "a tally week from 2020 is pruned" test ! -e "$R/tally/2020-W01"
assert "this week is kept" test -e "$R/events/$_now_wk"

# === the readers ============================================================
cli retro show
expect_rc 0 "retro show"
assert "show: the repo table" has "$OUT" "REPO"
assert "show: a pull counted, from the events" \
  has "$(printf '%s\n' "$OUT" | grep '^pulled ')" " 2 "
assert "show: declines with their reason" has "$OUT" "1 in-use"
assert "show: an episode, with its longest" has "$OUT" "1, longest"
assert "show: the config section" has "$OUT" "$HOME/cd/a.conf"
assert "show: unusual, by kind" has "$OUT" "could-not-run"
assert "show: never reviewed yet" has "$OUT" "last review: never"
_rows=$(printf '%s\n' "$OUT" | awk '/^REPO /{ r = 1; next } r && /^$/{ exit }
  r { print $1 }')
assert "show: the REPO table holds only repos (rows: $(printf '%s' \
  "$_rows" | tr '\n' ' '))" \
  test -z "$(printf '%s\n' "$_rows" | grep -vxE \
    'pulled|busy|ahead|pu|refused')"
assert "show: no nameless row" \
  test -z "$(printf '%s\n' "$OUT" | grep -E '^ +[0-9]+ +[0-9]+ +[0-9]+ ')"
assert "show: unusual events are listed, not made rows" \
  has "$OUT" "could-not-run"
cli retro events --class unusual
assert "events --class unusual: only unusual" \
  test -z "$(printf '%s\n' "$OUT" | grep -v ' unusual ')"
assert "events: a date, UTC" \
  has "$OUT" "$(date -u +%Y-%m-%d)"
cli retro tally
assert "tally: summed" has "$OUT" "run:ok"
cli retro status
assert "status: how far back" has "$OUT" "record since:"
cli retro 'done'
expect_rc 0 "retro done"
cli retro status
assert "status: the review is recorded" lacks "$OUT" "last review:   never"
cli retro show --since bogus
expect_rc 2 "a bad --since"
cli retro events --class nope
expect_rc 2 "a bad --class"
cli retro frobnicate
expect_rc 2 "an unknown retro command"
cli retro help
expect_rc 0 "retro help"
assert "help lists its commands" has "$OUT" "show [--since <age>]"

# === check asks for a review once a quarter of record has none =============
rm -f "$R/reviewed"
_old=$(( $(date +%s) - 100 * 86400 ))
printf 't=%s class=action kind=pulled origin=x where=y detail=-\n' "$_old" \
  > "$R/events/2000-W01"
OUT=$("$MUSTER" check 2>&1)
assert "check: a quarter of record and no review is a note" \
  has "$OUT" "note   retro      no review in over a quarter"
"$MUSTER" retro 'done' >/dev/null 2>&1
OUT=$("$MUSTER" check 2>&1)
assert "check: after a review, no note" lacks "$OUT" "retro      no review"
rm -f "$R/events/2000-W01"

h_verdict
