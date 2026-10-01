#!/bin/sh
# test/survey.t - `muster survey`, against real git repos built in a
# scratch directory. No stubs: the survey's whole job is reading git
# correctly, so a stubbed git would test the stub.
#
# Prints `ok   survey (N checks)` or `FAIL survey:` and every failure.
set -u

H_NAME=survey
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

# === states of a single repo =================================================

mkrepo clean
survey clean
expect clean state ok
expect clean branch main
expect clean upstream origin/main
expect clean ahead 0
expect clean behind 0
expect clean modified 0
expect clean untracked 0
expect clean deployed -
expect_rc 0 "a clean repo"
assert "clean: head is a 12-char sha" \
  test "$(field clean head | wc -c)" -eq 13
assert "clean: head equals upstream_head" \
  test "$(field clean head)" = "$(field clean upstream_head)"
assert "clean: a fresh clone has a fetch time, not never" \
  test "$(field clean fetched)" -gt 0

mkrepo modified
echo change >> "$ROOT/modified/f"
survey modified
expect modified state dirty
expect modified modified 1
expect modified untracked 0
expect_rc 1 "a dirty repo"

mkrepo staged
echo new > "$ROOT/staged/g"
g "$ROOT/staged" add g
survey staged
expect staged state dirty
expect staged modified 1
expect staged untracked 0

mkrepo untracked
echo new > "$ROOT/untracked/u1"
echo new > "$ROOT/untracked/u2"
survey untracked
expect untracked state dirty
expect untracked modified 0
expect untracked untracked 2

mkrepo ignored
echo '*.log' > "$ROOT/ignored/.gitignore"
g "$ROOT/ignored" add .gitignore
g "$ROOT/ignored" commit -m ignore
g "$ROOT/ignored" push
echo noise > "$ROOT/ignored/x.log"
survey ignored
expect ignored state ok
expect ignored untracked 0

# A user setting that hides untracked files must not hide work in progress.
mkrepo hidden
g "$ROOT/hidden" config status.showUntrackedFiles no
echo new > "$ROOT/hidden/u"
survey hidden
expect hidden state dirty
expect hidden untracked 1

mkrepo ahead
echo more >> "$ROOT/ahead/f"
g "$ROOT/ahead" commit -am local
survey ahead
expect ahead state ahead
expect ahead ahead 1
expect ahead behind 0

mkrepo behind
upstream_moves behind
g "$ROOT/behind" fetch
survey behind
expect behind state behind
expect behind behind 1
expect behind ahead 0

mkrepo diverged
upstream_moves diverged
g "$ROOT/diverged" fetch
echo mine > "$ROOT/diverged/h"
g "$ROOT/diverged" add h
g "$ROOT/diverged" commit -m mine
survey diverged
expect diverged state ahead,behind
expect diverged ahead 1
expect diverged behind 1

mkrepo dirtyahead
echo more >> "$ROOT/dirtyahead/f"
g "$ROOT/dirtyahead" commit -am local
echo wip > "$ROOT/dirtyahead/w"
survey dirtyahead
expect dirtyahead state ahead,dirty

# A local branch nobody pushed: its whole history is on this box.
mkrepo noup
g "$ROOT/noup" checkout -b local-only
survey noup
expect noup state no-upstream
expect noup branch local-only
expect noup upstream -
expect noup ahead -
expect noup behind -
expect noup fetched -

# Tracking configured, ref gone: deleted upstream, or never fetched.
mkrepo gone
g "$ROOT/gone" update-ref -d refs/remotes/origin/main
survey gone
expect gone state upstream-gone
expect gone upstream -

mkrepo detached
g "$ROOT/detached" checkout --detach
survey detached
expect detached state detached
expect detached branch -
assert "detached: head is still reported" test "$(field detached head)" != -

git init -q "$ROOT/unborn"
survey unborn
expect unborn state unborn,no-upstream
expect unborn head -
expect unborn branch main

# === R3: behind is only as current as the last fetch =========================

# Upstream moved, nobody fetched: the local ref still says 0, and the
# record must carry the fetch time that qualifies that 0.
mkrepo stale
upstream_moves stale
survey stale
expect stale behind 0
assert "stale: behind 0 is reported WITH its fetch time" \
  test "$(field stale fetched)" -gt 0
survey --fetch stale
expect stale behind 1
expect stale state behind
expect_rc 1 "--fetch finding the repo behind"
assert "--fetch: FETCH_HEAD now exists" test -f "$ROOT/stale/.git/FETCH_HEAD"

# A PURE clone of a non-empty origin writes neither FETCH_HEAD nor the
# branch's reflog, only origin/HEAD's. (mkrepo's push -u writes the
# branch reflog, so it cannot stand in for this case.)
git clone -q "$_T/origins/clean.git" "$ROOT/fresh" 2>/dev/null
assert "fixture: a fresh clone has no branch reflog" \
  test ! -e "$ROOT/fresh/.git/logs/refs/remotes/origin/main"
survey fresh
assert "fresh clone: has a fetch time, not never" \
  test "$(field fresh fetched)" -gt 0

# No FETCH_HEAD and no reflog: there is no evidence of contact, so never.
mkrepo never
rm -f "$ROOT/never/.git/FETCH_HEAD" \
  "$ROOT/never/.git/logs/refs/remotes/origin/main" \
  "$ROOT/never/.git/logs/refs/remotes/origin/HEAD"
survey never
expect never fetched never

# A fetch that cannot reach its remote is a FINDING, never "up to date".
mkrepo unreachable
g "$ROOT/unreachable" remote set-url origin "$_T/origins/nowhere.git"
survey --fetch unreachable
expect unreachable state fetch-failed
expect_rc 1 "a failed fetch"

# THE 2026-09-30 SHAPE: one run, upstream moved for both repos, one fetch
# fails. The failed repo must contribute NO number (its ref is stale and
# would say behind 0), and its reason must reach stderr.
mkrepo mixok
mkrepo mixbad
upstream_moves mixok
upstream_moves mixbad
g "$ROOT/mixbad" remote set-url origin "$_T/origins/gone-away.git"
survey --fetch mixok mixbad
expect mixok behind 1
expect mixok state behind
expect mixbad state fetch-failed
expect mixbad ahead -
expect mixbad behind -
expect_rc 1 "a run where one fetch failed"
assert "fetch failure: stderr names the repo" has "$ERR" "$ROOT/mixbad"
assert "fetch failure: stderr carries git's reason" has "$ERR" gone-away
assert "fetch failure: the good repo is not named on stderr" \
  test -z "$(printf '%s\n' "$ERR" | grep "$ROOT/mixok")"
# Without --fetch the same repo reports its (stale) counts, qualified by
# its fetch time, exactly as before: only a FAILED fetch voids them.
survey mixbad
expect mixbad behind 0

# A repo with nothing to fetch from is not a fetch failure.
mkrepo localonly
g "$ROOT/localonly" checkout -b solo
survey --fetch localonly
expect localonly state no-upstream

# A worktree's .git is a FILE; git-path still finds the fetch time.
mkrepo wtbase
g "$ROOT/wtbase" fetch
g "$ROOT/wtbase" worktree add -b wtb "$ROOT/wt" origin/main
survey wt
expect wt branch wtb
expect wt upstream origin/main
assert "worktree: has a fetch time" test "$(field wt fetched)" -gt 0

# === R4: unreadable is a third state, never absent ===========================

mkdir -p "$_T/probe"
chmod 000 "$_T/probe"
if [ -r "$_T/probe" ]; then
  CAN_LOCK=''   # running as root: permissions do not bind, so skip these
else
  CAN_LOCK=1
fi
chmod 755 "$_T/probe"

if [ -n "$CAN_LOCK" ]; then
  mkrepo locked
  chmod 000 "$ROOT/locked"
  survey locked
  expect locked state unreadable
  expect locked path "$ROOT/locked"
  expect_rc 1 "an unreadable repo"

  mkrepo lockedgit
  chmod 000 "$ROOT/lockedgit/.git"
  survey lockedgit
  expect lockedgit state unreadable

  # Search permission but no read: .git can still be stat'ed, git works.
  mkrepo noread
  chmod 311 "$ROOT/noread"
  survey noread
  expect noread state ok
fi

survey nosuch
expect nosuch state absent
expect_rc 1 "an absent repo"

mkdir "$ROOT/plain"
survey plain
expect plain state not-a-repo

echo hello > "$ROOT/afile"
survey afile
expect afile state not-a-repo

mkdir "$ROOT/broken"
echo 'gitdir: /nonexistent/elsewhere' > "$ROOT/broken/.git"
survey broken
expect broken state broken

# A non-repo inside a repo must not borrow its parent's answer.
mkrepo parent
mkdir "$ROOT/parent/sub"
survey parent/sub
expect parent/sub state not-a-repo
# An EMPTY .git directory: git would walk up and answer for the parent,
# unless the ceiling stops it.
mkdir -p "$ROOT/parent/hollow/.git"
survey parent/hollow
expect parent/hollow state broken

# === discovery ===============================================================
# A root of its own, so the fixtures above do not crowd it.
D=$_T/disc
mkdir -p "$D"
mkd() {   # <name>: a committed repo with no remote, under $D
  git init -q "$D/$1"
  echo x > "$D/$1/f"
  g "$D/$1" add f
  g "$D/$1" commit -m x
}
mkd zeta
mkd alpha
mkd mid
mkdir "$D/notrepo"
echo x > "$D/afile"
ln -s "$D/afile" "$D/CLAUDE.md"
mkdir "$D/.hidden"
git init -q "$D/.hidden/x"
MUSTER_ROOT=$D survey
assert "discovery: the repos, sorted, and nothing else" \
  test "$(printf '%s\n' "$OUT" | awk '{print $1}' | tr '\n' ' ')" \
  = "name=alpha name=mid name=zeta "
expect_rc 1 "discovery over repos with no upstream"
if [ -n "$CAN_LOCK" ]; then
  mkdir "$D/sealed"
  chmod 000 "$D/sealed"
  MUSTER_ROOT=$D survey
  expect sealed state unreadable
  assert "discovery: an unreadable dir is LISTED, not skipped" \
    test -n "$(rec sealed)"
  chmod 755 "$D/sealed"
  rmdir "$D/sealed"
fi

E=$_T/empty
mkdir "$E"
MUSTER_ROOT=$E survey
expect_rc 2 "a root with no repos"
assert "no repos: says so" test -n "$ERR"
MUSTER_ROOT=$_T/nonexistent survey
expect_rc 2 "a root that does not exist"
if [ -n "$CAN_LOCK" ]; then
  mkdir "$_T/lockedroot"
  chmod 000 "$_T/lockedroot"
  MUSTER_ROOT=$_T/lockedroot survey
  expect_rc 2 "an unreadable root"
  chmod 755 "$_T/lockedroot"
fi

# === every record has every key, in order ===================================
KEYS='name state branch head upstream upstream_head ahead behind fetched'
KEYS="$KEYS modified untracked deployed path"
survey clean nosuch plain unborn detached
assert "five records for five names" \
  test "$(printf '%s\n' "$OUT" | wc -l)" -eq 5
assert "every record carries every key, in order" \
  test -z "$(printf '%s\n' "$OUT" | awk -v want="$KEYS" '{
    s = ""
    for (i = 1; i <= NF; i++) { k = $i; sub(/=.*/, "", k); s = s " " k }
    if (substr(s, 2) != want) print
  }')"
assert "no value is empty" \
  test -z "$(printf '%s\n' "$OUT" | tr ' ' '\n' | grep '=$')"

# === escaping: a field can never contain the separator ======================
S=$_T/esc
mkdir -p "$S"
TAB=$(printf '\t')
NL='
'
for _n in "has space" "tab${TAB}in" "pct%25" "new${NL}line"; do
  git init -q "$S/$_n"
done
MUSTER_ROOT=$S survey
assert "four odd names, four records" \
  test "$(printf '%s\n' "$OUT" | wc -l)" -eq 4
assert "every record has exactly 13 fields" \
  test -z "$(printf '%s\n' "$OUT" | awk 'NF != 13')"
expect "has%20space" state unborn,no-upstream
expect "tab%09in" state unborn,no-upstream
expect "pct%2525" state unborn,no-upstream
expect "new%0Aline" state unborn,no-upstream
expect "has%20space" path "$S/has%20space"
# The table renders the same four.
OUTT=$(MUSTER_ROOT=$S "$MUSTER" survey 2>/dev/null)
assert "table: header plus four rows" \
  test "$(printf '%s\n' "$OUTT" | wc -l)" -eq 5

# === config: the integrator's facts ==========================================
C=$_T/cfg
mkdir -p "$C" "$HOME/elsewhere"
git init -q "$HOME/elsewhere/tilde"
mkdir -p "$_T/with space"
git init -q "$_T/with space/spaced"
cat > "$C/repos" <<CFG
# a comment, and a blank line

repo zeta
repo tilde ~/elsewhere/tilde
repo spaced $_T/with space/spaced
root $D
CFG
MUSTER_ROOT='' MUSTER_CONFIG=$C/repos survey
assert "config: the declared set, in declared order" \
  test "$(printf '%s\n' "$OUT" | awk '{print $1}' | tr '\n' ' ')" \
  = "name=zeta name=tilde name=spaced "
expect zeta path "$D/zeta"
expect tilde path "$HOME/elsewhere/tilde"
expect spaced path "$(printf '%s' "$_T/with space/spaced" | sed 's/ /%20/g')"
expect spaced state unborn,no-upstream

# The environment beats the config's root, so a caller can point anywhere.
MUSTER_ROOT=$ROOT MUSTER_CONFIG=$C/repos survey zeta
expect zeta state absent

# A name on the command line narrows the declared set.
MUSTER_ROOT='' MUSTER_CONFIG=$C/repos survey tilde
assert "config: a named repo resolves through the config" \
  test "$(printf '%s\n' "$OUT" | wc -l)" -eq 1
expect tilde path "$HOME/elsewhere/tilde"

printf 'repo zeta\nrepos alpha\n' > "$C/typo"
MUSTER_CONFIG=$C/typo survey
expect_rc 2 "an unknown directive"
assert "an unknown directive names its line" has "$ERR" typo:2:

printf 'deployed zeta\n' > "$C/short"
MUSTER_CONFIG=$C/short survey
expect_rc 2 "deployed without a path"

printf 'repo alpha' > "$C/nonl"
MUSTER_ROOT=$D MUSTER_CONFIG=$C/nonl survey
assert "a last line with no newline is still read" \
  test -n "$(rec alpha)"

if [ -n "$CAN_LOCK" ]; then
  printf 'repo alpha\n' > "$C/locked"
  chmod 000 "$C/locked"
  MUSTER_CONFIG=$C/locked survey
  expect_rc 2 "an unreadable config"
  chmod 644 "$C/locked"
fi

# The default config path, under HOME, is read when MUSTER_CONFIG is unset.
mkdir -p "$HOME/.config/muster"
printf 'repo mid\n' > "$HOME/.config/muster/repos"
OUT=$(unset MUSTER_CONFIG; MUSTER_ROOT=$D "$MUSTER" survey --porcelain)
assert "the default config path is honoured" \
  test "$(printf '%s\n' "$OUT" | awk '{print $1}')" = name=mid
rm -f "$HOME/.config/muster/repos"

# === R2: the deployed clone, the third head ==================================
mkrepo pkg
P=$_T/deployed
mkdir -p "$P"
git clone -q "$_T/origins/pkg.git" "$P/pkg" 2>/dev/null
printf 'deployed pkg %s/pkg\n' "$P" > "$C/dep"
MUSTER_CONFIG=$C/dep survey pkg
expect pkg state ok
assert "deployed: matches origin, reported as its sha" \
  test "$(field pkg deployed)" = "$(field pkg upstream_head)"

upstream_moves pkg
g "$ROOT/pkg" fetch
g "$ROOT/pkg" merge --ff-only
MUSTER_CONFIG=$C/dep survey pkg
expect pkg state deployed-differs
assert "deployed: behind origin is a differing sha" \
  test "$(field pkg deployed)" != "$(field pkg upstream_head)"
OUTT=$(MUSTER_CONFIG=$C/dep "$MUSTER" survey pkg 2>/dev/null)
assert "table: a deployed clone gets its own line" \
  has "$OUTT" "deployed $(field pkg deployed)"

# Deployed clone caught up; the DEV checkout is now the odd one out, which
# is ahead, not a deployed problem.
g "$P/pkg" pull
echo dev >> "$ROOT/pkg/f"
g "$ROOT/pkg" commit -am dev
MUSTER_CONFIG=$C/dep survey pkg
expect pkg state ahead

printf 'deployed pkg %s/gone\n' "$P" > "$C/dep2"
MUSTER_CONFIG=$C/dep2 survey pkg
expect pkg deployed absent
expect pkg state ahead,deployed-absent

mkdir "$P/notrepo"
printf 'deployed pkg %s/notrepo\n' "$P" > "$C/dep3"
MUSTER_CONFIG=$C/dep3 survey pkg
expect pkg deployed not-a-repo

# No upstream: the deployed clone is compared with the dev HEAD.
mkd solo
git clone -q "$D/solo" "$P/solo" 2>/dev/null
printf 'deployed solo %s/solo\n' "$P" > "$C/dep4"
MUSTER_ROOT=$D MUSTER_CONFIG=$C/dep4 survey solo
expect solo state no-upstream
echo more >> "$D/solo/f"
g "$D/solo" commit -am more
MUSTER_ROOT=$D MUSTER_CONFIG=$C/dep4 survey solo
expect solo state no-upstream,deployed-differs

# === read-only: the survey writes nothing ====================================
mkrepo ro
touch "$ROOT/ro/f"   # stat-dirty, so a plain `git status` WOULD rewrite index
sleep 1
touch "$_T/marker"
survey ro
assert "read-only: nothing under .git changed" \
  test -z "$(find "$ROOT/ro/.git" -newer "$_T/marker")"
assert "read-only: nothing in the work tree changed" \
  test -z "$(find "$ROOT/ro" -newer "$_T/marker")"

# === a caller inside a git hook ==============================================
# Hooks export GIT_DIR; `git -C` would obey it and describe the wrong repo.
# The decoy is on ANOTHER BRANCH, so obeying it changes the answer rather
# than coinciding with it (the first version of this test passed with the
# unset removed, because the decoy happened to read the same).
mkrepo hooked
echo wip > "$ROOT/hooked/w"
OUT=$(GIT_DIR=$ROOT/noup/.git "$MUSTER" survey --porcelain hooked 2>/dev/null)
expect hooked branch main
expect hooked state dirty
OUT=$(GIT_DIR=$ROOT/noup/.git GIT_WORK_TREE=$ROOT/noup \
  "$MUSTER" survey --porcelain hooked 2>/dev/null)
expect hooked branch main
expect hooked untracked 1

# === the command line ========================================================
cli() {
  OUT=$("$MUSTER" "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}
cli
expect_rc 2 "no command"
cli frobnicate
expect_rc 2 "an unknown command"
cli help
expect_rc 0 "help"
assert "help: shows usage" starts "$OUT" usage:
cli survey --bogus
expect_rc 2 "an unknown option"
cli survey ''
expect_rc 2 "an empty name"
cli survey --porcelain -- clean
expect_rc 0 "-- ends the options"
cli survey clean
expect_rc 0 "table, all ok"
assert "table: has a header" starts "$OUT" REPO

# === R10: the table and the porcelain are one computation ====================
# The names, as the positional parameters, so every use is "$@".
set -- clean modified ahead behind noup gone detached unborn nosuch plain
OUTP=$("$MUSTER" survey --porcelain "$@" 2>/dev/null); RCP=$?
OUTT=$("$MUSTER" survey "$@" 2>/dev/null); RCT=$?
assert "R10: same exit from both views" test "$RCP" = "$RCT"
assert "R10: one table row per record, plus the header" \
  test "$(printf '%s\n' "$OUTT" | wc -l)" \
  -eq "$(( $(printf '%s\n' "$OUTP" | wc -l) + 1 ))"
assert "R10: every record's name and state appear on its table row" \
  test -z "$(printf '%s\n' "$OUTP" | while read -r _r; do
    _nm=$(printf '%s\n' "$_r" | tr ' ' '\n' | sed -n 's/^name=//p')
    _st=$(printf '%s\n' "$_r" | tr ' ' '\n' | sed -n 's/^state=//p')
    printf '%s\n' "$OUTT" | awk -v n="$_nm" -v s="$_st" \
      '$1 == n && $NF == s { f = 1 } END { exit !f }' || echo "$_nm"
  done)"

# A malformed record is a failure of the renderer, never a silent pass.
# shellcheck source=SCRIPTDIR/../lib/survey_lib
. "$HERE/../lib/survey_lib"
printf 'garbage\n' | _sv_render porcelain >/dev/null 2>&1
assert "a malformed record fails the render" test "$?" = 1

# === every shell this has to run under =======================================
# Same records, byte for byte, from each interpreter present.
BASE=$(sh "$MUSTER" survey --porcelain "$@" 2>/dev/null)
for _sh in dash bash ksh mksh zsh; do
  command -v "$_sh" >/dev/null 2>&1 || continue
  _o=$("$_sh" "$MUSTER" survey --porcelain "$@" 2>&1)
  assert "$_sh: the same records as sh" test "$_o" = "$BASE"
done

# === installed by symlink, and with lib/ missing =============================
mkdir -p "$_T/bin"
ln -s "$MUSTER" "$_T/bin/muster"
OUT=$("$_T/bin/muster" survey --porcelain clean 2>/dev/null)
expect clean state ok
mkdir -p "$_T/orphan/bin"
cp "$MUSTER" "$_T/orphan/bin/muster"
"$_T/orphan/bin/muster" survey >/dev/null 2>&1
assert "lib/ missing: exit 2, not a crash mid-run" test "$?" = 2

h_verdict
