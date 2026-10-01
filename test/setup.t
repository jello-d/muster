#!/bin/sh
# test/setup.t - setup.sh, the pkg contract tackup installs through:
# install, the four-question check (including shadowing and a link that
# does not run), and an uninstall that only ever removes its own link.
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
case $B in
  "$_T"/*) ;;
  *) echo "FAIL setup: bin dir [$B] is outside the scratch dir"; exit 1 ;;
esac
unset XDG_BIN_HOME
export NO_COLOR=1
# st [args...]: run setup.sh. stp <PATH> [args...]: the same under a given
# PATH, passed through env so it cannot leak into the rest of this file
# (an assignment before a FUNCTION call may persist after it in POSIX sh).
st() { stp "$PATH" "$@"; }
stp() {
  _s_path=$1; shift
  OUT=$(env PATH="$_s_path" sh "$SETUP" "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}

st check
expect_rc 1 "check before install"
assert "check: says it is not installed" has "$OUT" "muster not installed"

st install
expect_rc 0 "install"
assert "install: a link to this tree's bin/muster" \
  test "$(readlink "$B/muster")" = "$TREE/bin/muster"
st install
expect_rc 0 "install again (idempotent)"

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

# A link that resolves but does not run (its tree lost lib/).
mkdir -p "$_T/broken/bin"
cp "$TREE/bin/muster" "$_T/broken/bin/muster"
ln -sfn "$_T/broken/bin/muster" "$B/muster"
stp "$B:$PATH" check
expect_rc 1 "check with a link to another tree"
assert "check: not this tree's link" has "$OUT" "is not a link to this tree"
assert "check: and it does not run" has "$OUT" "does not run"

# uninstall removes only OUR link.
st uninstall
assert "uninstall: someone else's link is left alone" test -L "$B/muster"
assert "uninstall: and says so" has "$OUT" "left alone"
st install
st uninstall
assert "uninstall: our link is removed" test ! -e "$B/muster"

st version
assert "version" starts "$OUT" "muster "
st bogus
expect_rc 2 "an unknown verb"

h_verdict
