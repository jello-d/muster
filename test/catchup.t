#!/bin/sh
# test/catchup.t - `muster catch-up`, the first verb that writes. Every
# action is checked for what it did AND for what it left alone, and every
# failure path is driven for real: a rebase refused by a hook, a rebase
# that alters local work, a repo that moves between judging and acting.
#
# Prints `ok   catch-up (N checks)` or `FAIL catch-up:` and every failure.
set -u

H_NAME=catch-up
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

# catchup [args...]: run it, porcelain, into OUT / ERR / RC
catchup() {
  OUT=$("$MUSTER" catch-up --porcelain "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}
commit_file() {   # <repo> <file> <content> <message>
  mkdir -p "$(dirname -- "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  g "$1" add -- "$2"
  g "$1" commit -m "$4"
}
head_of() { git -C "$1" rev-parse HEAD; }
short() { printf '%.12s' "$1"; }
origin_head() { git --git-dir="$_T/origins/$1.git" rev-parse main; }

# === pull: a fast-forward, landing exactly on the upstream ==================
mkrepo behind
upstream_moves behind
_was=$(head_of "$ROOT/behind")
catchup --dry-run behind
expect behind action pull
expect behind result dry-run
assert "dry-run: HEAD did not move" test "$(head_of "$ROOT/behind")" = "$_was"
expect_rc 1 "a dry run: the pull is still owed"
catchup behind
expect behind action pull
expect behind result ok
expect behind remaining nothing
expect behind from "$(short "$_was")"
expect behind to "$(short "$(origin_head behind)")"
assert "pull: HEAD is exactly origin's" \
  test "$(head_of "$ROOT/behind")" = "$(origin_head behind)"
assert "pull: the work tree is clean after" \
  test -z "$(git -C "$ROOT/behind" status --porcelain)"
expect_rc 0 "a run that leaves nothing owed"

# Idempotent: a second run has nothing to do.
catchup behind
expect behind action none
expect behind result -
expect_rc 0 "the second run"

# === rebase: disjoint sides, local work carried through =====================
mkrepo disjoint
upstream_moves disjoint
commit_file "$ROOT/disjoint" mine "my work" local
_local_diff=$(git -C "$ROOT/disjoint" show --format= HEAD)
catchup disjoint
expect disjoint action rebase
expect disjoint result ok
expect disjoint remaining push
expect_rc 1 "a rebase leaves a push owed"
assert "rebase: origin's head is now an ancestor" \
  git -C "$ROOT/disjoint" merge-base --is-ancestor \
  "$(origin_head disjoint)" HEAD
assert "rebase: the local commit's change is byte-identical" \
  test "$(git -C "$ROOT/disjoint" show --format= HEAD)" = "$_local_diff"
assert "rebase: exactly one commit ahead" \
  test "$(git -C "$ROOT/disjoint" rev-list --count origin/main..HEAD)" = 1
assert "rebase: never pushed" \
  test "$(origin_head disjoint)" != "$(head_of "$ROOT/disjoint")"

# === never touched ===========================================================
untouched() {   # <repo> <description>: HEAD and status exactly as before
  assert "$2: HEAD did not move" test "$(head_of "$ROOT/$1")" = "$_h"
  assert "$2: the work tree is as it was" \
    test "$(git -C "$ROOT/$1" status --porcelain)" = "$_s"
}
snap() { _h=$(head_of "$ROOT/$1"); _s=$(git -C "$ROOT/$1" status --porcelain); }

mkrepo overlap
upstream_moves overlap
echo local >> "$ROOT/overlap/f"
g "$ROOT/overlap" commit -am local
snap overlap
catchup overlap
expect overlap action none
expect overlap remaining escalate
untouched overlap "escalate"

mkrepo dirty
upstream_moves dirty
echo wip >> "$ROOT/dirty/f"
snap dirty
catchup dirty
expect dirty action none
expect dirty remaining skip
untouched dirty "skip"
assert "skip: the work in progress survived" \
  has "$(cat "$ROOT/dirty/f")" wip

mkrepo unreach
upstream_moves unreach
g "$ROOT/unreach" remote set-url origin "$_T/origins/lost.git"
snap unreach
catchup unreach
expect unreach action none
expect unreach remaining unknown
untouched unreach "unknown"

mkrepo ahead
commit_file "$ROOT/ahead" mine "x" local
snap ahead
catchup ahead
expect ahead action none
expect ahead remaining push
untouched ahead "ahead only"

# === the failure paths, driven for real ======================================

# A rebase refused (here by a pre-rebase hook) is aborted, and the abort is
# PROVEN to restore the starting commit.
mkrepo refused
upstream_moves refused
commit_file "$ROOT/refused" mine "x" local
printf '#!/bin/sh\nexit 1\n' > "$ROOT/refused/.git/hooks/pre-rebase"
chmod +x "$ROOT/refused/.git/hooks/pre-rebase"
snap refused
catchup refused
expect refused action rebase
expect refused result aborted
expect refused to "$(short "$_h")"
untouched refused "aborted rebase"
expect_rc 1 "an aborted rebase"
assert "aborted: no rebase left in progress" \
  test ! -d "$ROOT/refused/.git/rebase-merge"
assert "aborted: stderr says so" has "$ERR" "rebase failed and was aborted"

# A rebase whose result does not carry the local work through unchanged is
# put back. Here a post-rewrite hook slips an extra change in after it.
mkrepo altered
upstream_moves altered
commit_file "$ROOT/altered" mine "x" local
cat > "$ROOT/altered/.git/hooks/post-rewrite" <<'HOOK'
#!/bin/sh
echo sneaky >> mine
git commit -qam sneaky
HOOK
chmod +x "$ROOT/altered/.git/hooks/post-rewrite"
snap altered
catchup altered
expect altered action rebase
expect altered result reverted
untouched altered "reverted rebase"
assert "reverted: stderr says what happened" \
  has "$ERR" "the rebase changed the local work"
expect_rc 1 "a reverted rebase"

# The repo moved between judging and acting (R9). The acting functions are
# called directly with a verdict that is now stale.
mkrepo raced
upstream_moves raced
# shellcheck source=SCRIPTDIR/../lib/survey_lib
. "$HERE/../lib/survey_lib"
# shellcheck source=SCRIPTDIR/../lib/owed_lib
. "$HERE/../lib/owed_lib"
# shellcheck source=SCRIPTDIR/../lib/catchup_lib
. "$HERE/../lib/catchup_lib"
g "$ROOT/raced" fetch
SV_CONFIG=$_T/no-config SV_DO_FETCH='' CU_DRY=''
survey_record raced "$ROOT/raced" >/dev/null
echo racing > "$ROOT/raced/untracked-now"
snap raced
_cu_pull "$ROOT/raced"
assert "raced pull: changed-underfoot" test "$CU_RESULT" = changed-underfoot
untouched raced "raced pull"
rm -f "$ROOT/raced/untracked-now"
upstream_moves raced   # origin moves again; the recorded upref is stale
g "$ROOT/raced" fetch
snap raced
_cu_pull "$ROOT/raced"
assert "raced pull, upstream moved: changed-underfoot" \
  test "$CU_RESULT" = changed-underfoot
untouched raced "raced pull, upstream moved"
survey_record raced "$ROOT/raced" >/dev/null
commit_file "$ROOT/raced" mine "x" local   # HEAD moves after judging
snap raced
_cu_rebase "$ROOT/raced"
assert "raced rebase: changed-underfoot" test "$CU_RESULT" = changed-underfoot
untouched raced "raced rebase"

# Defence in depth: owed never sends a diverged repo to the pull path, but
# if a stale or wrong verdict ever did, the fast-forward must refuse and
# move NOTHING, rather than make a merge commit nobody asked for.
mkrepo forked
upstream_moves forked
commit_file "$ROOT/forked" mine "x" local
g "$ROOT/forked" fetch
survey_record forked "$ROOT/forked" >/dev/null
snap forked
_cu_pull "$ROOT/forked" 2>/dev/null
assert "pull on a diverged repo: failed" test "$CU_RESULT" = failed
untouched forked "pull on a diverged repo"

# A failed action is a failure even if the repo ends up owing nothing
# (someone else caught it up meanwhile): the exit must still say look.
cu_rec() {   # <result>: one record that owes nothing after
  printf 'name=x action=pull result=%s from=a to=b owed=pull %s\n' \
    "$1" 'remaining=nothing path=/x'
}
cu_rec failed | _cu_render porcelain >/dev/null 2>&1
assert "a failed action fails the run even with nothing remaining" \
  test "$?" = 1
cu_rec ok | _cu_render porcelain >/dev/null 2>&1
assert "an ok action with nothing remaining passes" test "$?" = 0

# === the canonical's own repo is caught up FIRST ============================
# The box A shape, 2026-10-01: the copies are already current, but
# the canonical's checkout is behind, so nothing can be judged until it is
# pulled. One run must pull it AND then judge the copies against it.
mkrepo notes
commit_file "$ROOT/notes" _conv "v1" v1
g "$ROOT/notes" push
git clone -q "$_T/origins/notes.git" "$_T/other/notes" 2>/dev/null
commit_file "$_T/other/notes" _conv "v2" v2
g "$_T/other/notes" push
mkrepo carrier
commit_file "$ROOT/carrier" test/conv.t "v2" seeded-v2
g "$ROOT/carrier" push
C=$_T/cfg
mkdir -p "$C"
printf 'artifact %s/_conv test/conv.t\n' "$ROOT/notes" > "$C/art"
printf 'repo carrier\nrepo notes\n' >> "$C/art"
_notes_was=$(head_of "$ROOT/notes")

# Asked about the carrier alone, the canonical is NOT touched.
MUSTER_CONFIG=$C/art catchup carrier
assert "named run: the canonical's repo was not pulled" \
  test "$(head_of "$ROOT/notes")" = "$_notes_was"
expect carrier remaining unknown

MUSTER_CONFIG=$C/art catchup
expect notes action pull
expect notes result ok
expect notes remaining nothing
expect carrier remaining nothing
expect_rc 0 "one run: canonical pulled, copies judged against it"
assert "canonical: HEAD is origin's" \
  test "$(head_of "$ROOT/notes")" = "$(origin_head notes)"
assert "the canonical's repo has exactly one row" \
  test "$(printf '%s\n' "$OUT" | grep -c '^name=notes ')" = 1
assert "no untrusted-canonical warning after the pre-pass" \
  test -z "$ERR"

# === a whole run: mixed verdicts, one table, one exit =======================
set -- behind disjoint overlap dirty unreach ahead
OUTP=$("$MUSTER" catch-up --porcelain --dry-run "$@" 2>/dev/null); RCP=$?
OUTT=$("$MUSTER" catch-up --dry-run "$@" 2>/dev/null); RCT=$?
assert "R10: same exit from both views" test "$RCP" = "$RCT"
assert "R10: one table row per record, plus the header" \
  test "$(printf '%s\n' "$OUTT" | wc -l)" \
  -eq "$(( $(printf '%s\n' "$OUTP" | wc -l) + 1 ))"
assert "table: has a header" starts "$OUTT" REPO
KEYS='name action result from to owed remaining state fetched path'
assert "every record carries every key, in order" \
  test -z "$(printf '%s\n' "$OUTP" | awk -v want="$KEYS" '{
    s = ""
    for (i = 1; i <= NF; i++) { k = $i; sub(/=.*/, "", k); s = s " " k }
    if (substr(s, 2) != want) print
  }')"
assert "no value is empty" \
  test -z "$(printf '%s\n' "$OUTP" | tr ' ' '\n' | grep '=$')"

# Two repos owed a pull in one run, one of whose fetch fails: the good one
# is pulled, the other is left exactly as it was.
mkrepo pairok
mkrepo pairbad
upstream_moves pairok
upstream_moves pairbad
g "$ROOT/pairbad" remote set-url origin "$_T/origins/elsewhere.git"
snap pairbad
"$MUSTER" catch-up --porcelain pairok pairbad >/dev/null 2>&1
assert "mixed run: the good repo was pulled" \
  test "$(head_of "$ROOT/pairok")" = "$(origin_head pairok)"
untouched pairbad "mixed run, the failed fetch"

cli() {
  OUT=$("$MUSTER" "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}
cli catch-up --bogus
expect_rc 2 "catch-up: an unknown option"
cli catch-up ''
expect_rc 2 "catch-up: an empty name"

printf 'garbage\n' | _cu_render porcelain >/dev/null 2>&1
assert "a malformed record fails the render" test "$?" = 1

h_verdict
