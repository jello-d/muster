#!/bin/sh
# test/setup.t - setup.sh, the pkg contract tackup installs through:
# install as a payload copied out of the tree, the check (payload drift,
# shadowing, a link that does not run, a link left into the clone), the
# payload surviving its source tree, and an uninstall that only ever
# removes what it built.
#
# Prints `ok   setup (N checks)` or `FAIL setup:` and every failure.
set -u

H_NAME=setup
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

SETUP=$HERE/../setup.sh
TREE=$(CDPATH='' cd -- "$HERE/.." && pwd -P)
export PREFIX="$_T/prefix"
B=$PREFIX/bin
P=$PREFIX/share/muster
case $B in
  "$_T"/*) ;;
  *) echo "FAIL setup: bin dir [$B] is outside the scratch dir"; exit 1 ;;
esac
unset XDG_BIN_HOME XDG_DATA_HOME
export NO_COLOR=1
# st [args...]: run setup.sh. stp <PATH> [args...]: the same under a given
# PATH, passed through env so it cannot leak into the rest of this file
# (an assignment before a FUNCTION call may persist after it in POSIX sh).
st() { stp "$PATH" "$@"; }
stp() {
  _s_path=$1; shift
  OUT=$(env PATH="$_s_path" "${MUSTER_SHELL:-sh}" "$SETUP" "$@" \
    2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}

st check
expect_rc 1 "check before install"
assert "check: says it is not installed" has "$OUT" "muster not installed"

st install
expect_rc 0 "install"
assert "install: the payload is a real directory" test -d "$P" -a ! -L "$P"
assert "install: the link points into the payload" \
  test "$(readlink "$B/muster")" = "$P/bin/muster"
assert "install: bin/ is a copy" cmp -s "$P/bin/muster" "$TREE/bin/muster"
assert "install: lib/ is a copy" diff -r "$TREE/lib" "$P/lib"
assert "install: no staging dirs left" test ! -e "$P.new" -a ! -e "$P.old"
echo extra > "$P/lib/stray"
st install
expect_rc 0 "install again (idempotent)"
assert "install again: the payload is rebuilt whole, not overlaid" \
  test ! -e "$P/lib/stray"
assert "install again: no staging dirs left" \
  test ! -e "$P.new" -a ! -e "$P.old"

# Reachable on PATH, and resolving to this install.
stp "$B:$PATH" check
expect_rc 0 "check after install, on PATH"
assert "check: PATH resolves to this install" \
  has "$OUT" "PATH resolves to this install"
assert "check: the installed link runs" has "$OUT" "the installed muster runs"
quiet() { "$@" >/dev/null 2>&1; }
assert "the installed link really runs" quiet "$B/muster" help

# Installed but not on this PATH: a warning, never a failure.
st check
expect_rc 0 "check with the bin dir off PATH"
assert "check: off PATH is a WARN" has "$OUT" "[WARN] muster installed at"

# Shadowed: another muster earlier on PATH.
mkdir -p "$_T/shadow"
printf '#!/bin/sh\necho stale\n' > "$_T/shadow/muster"
chmod +x "$_T/shadow/muster"
stp "$_T/shadow:$B:$PATH" check
expect_rc 1 "check with a shadowing copy"
assert "check: names the shadow" has "$OUT" "(shadowed)"

# The payload drifted from the tree: a FAIL that install repairs.
echo '# edited' >> "$P/lib/survey_lib"
stp "$B:$PATH" check
expect_rc 1 "check with a drifted payload"
assert "check: names the drifted dir" has "$OUT" "payload's lib/ differs"
st install
stp "$B:$PATH" check
expect_rc 0 "check after install repairs the drift"

# A link left into the clone (the era before the payload).
mkdir -p "$PREFIX/share/applications"
ln -s "$TREE/README.md" "$PREFIX/share/applications/stale"
stp "$B:$PATH" check
expect_rc 1 "check with a link into the clone"
assert "check: names the link into the clone" \
  has "$OUT" "share/applications/stale links into this tree"
rm -f "$PREFIX/share/applications/stale"

# A link that resolves but does not run (its tree lost lib/).
mkdir -p "$_T/broken/bin"
cp "$TREE/bin/muster" "$_T/broken/bin/muster"
ln -sfn "$_T/broken/bin/muster" "$B/muster"
stp "$B:$PATH" check
expect_rc 1 "check with a link to another tree"
assert "check: not a link into the payload" \
  has "$OUT" "is not a link into the payload"
assert "check: and it does not run" has "$OUT" "does not run"

# uninstall removes only OUR link, and the payload it built.
st uninstall
assert "uninstall: someone else's link is left alone" test -L "$B/muster"
assert "uninstall: and says so" has "$OUT" "left alone"
assert "uninstall: the payload goes anyway" test ! -e "$P"
st install
st uninstall
assert "uninstall: our link is removed" test ! -e "$B/muster"
assert "uninstall: the payload is removed" test ! -e "$P"
# The era of links into the clone: that link is ours too.
mkdir -p "$B"
ln -s "$TREE/bin/muster" "$B/muster"
st uninstall
assert "uninstall: a link into the clone is removed" test ! -e "$B/muster"

# A directory at the payload path that this script did not build is
# never deleted, and never replaced.
mkdir -p "$P/bin"
echo mine > "$P/bin/keep"
st install
expect_rc 1 "install over a foreign payload dir"
assert "install: refuses a foreign payload" has "$ERR" "left alone"
assert "install: the foreign dir is untouched" test -f "$P/bin/keep"
assert "install: its refused staging is cleaned up" test ! -e "$P.new"
st uninstall
expect_rc 1 "uninstall over a foreign payload dir"
assert "uninstall: refuses it loudly" has "$ERR" "no .muster-payload"
assert "uninstall: and leaves it" test -f "$P/bin/keep"
rm -f "$P/bin/keep"
rmdir "$P/bin" "$P"

# THE POINT OF THE PAYLOAD: the install outlives its source tree. A
# scratch copy of the tree installs, then is moved away entirely.
C=$_T/clone
mkdir -p "$C"
cp -R "$TREE/bin" "$TREE/lib" "$TREE/setup.sh" "$C/"
OUT=$(env PATH="$PATH" sh "$C/setup.sh" install 2>&1 </dev/null)
RC=$?
expect_rc 0 "install from a scratch clone"
mv "$C" "$_T/clone.gone"
assert "the installed muster runs with its source tree gone" \
  quiet "$B/muster" help
mv "$_T/clone.gone" "$C"
OUT=$(env PATH="$PATH" sh "$C/setup.sh" uninstall 2>&1 </dev/null)

st paths
expect_rc 0 "paths"
assert "paths: bin" has "$OUT" "bin	$B/muster"
assert "paths: payload" has "$OUT" "payload	$P"
assert "paths: config" has "$OUT" "config	"
assert "paths: state" has "$OUT" "state	"

st version
assert "version" starts "$OUT" "muster "
st bogus
expect_rc 2 "an unknown verb"

h_verdict
