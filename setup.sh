#!/bin/sh
# setup.sh - install / uninstall / check / test muster. The single entry
# point a consumer or provisioning layer uses (tackup's pkg contract).
#
#   ./setup.sh install     symlink bin/muster into ~/.local/bin
#   ./setup.sh uninstall   remove that symlink, only if it is ours
#   ./setup.sh check       installed, reachable, not shadowed, and it RUNS;
#                          [OK]/[FAIL]/[WARN] markers, exit 1 on a FAIL
#   ./setup.sh test        run the in-repo suite (test/run)
#   ./setup.sh version     the packaged version
#
# POSIX sh, non-privileged: muster reads the user's own checkouts and
# nothing root touches, so it lives in ~/.local (the house install-
# placement rule). Honors PREFIX and XDG_BIN_HOME so a test sandboxes it.
#
# ONLY bin/ IS LINKED. bin/muster resolves its own symlink to find lib/
# beside it in this tree, so there is nothing else to place and no second
# copy of anything to drift. Timers are NOT installed here: they are
# generated from the integrator's profiles by `muster schedule install`.
set -eu

PKG=muster
VERSION=0.1.0
_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

if [ -z "${HOME:-}" ]; then
  HOME=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)
  [ -n "$HOME" ] \
    || { echo "$PKG: HOME unset and not derivable from passwd" >&2; exit 1; }
  export HOME
fi

PREFIX=${PREFIX:-$HOME/.local}
_bin=${XDG_BIN_HOME:-$PREFIX/bin}
# HARD: the survey cannot run without them. SOFT: one verb degrades.
DEPS_HARD="git awk sed"
DEPS_SOFT="systemctl timeout"
RC=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _G=$(printf '\033[32m'); _R=$(printf '\033[31m')
  _Y=$(printf '\033[33m'); _O=$(printf '\033[0m')
else _G=''; _R=''; _Y=''; _O=''; fi
ok()   { printf '  %s[OK]%s   %s\n' "$_G" "$_O" "$1"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$_R" "$_O" "$1"; RC=1; }
warn() { printf '  %s[WARN]%s %s\n' "$_Y" "$_O" "$1"; }

do_install() {
  mkdir -p "$_bin"
  ln -sfn "$_root/bin/muster" "$_bin/muster"
  echo "$PKG: linked muster into $_bin"
}

do_uninstall() {
  if [ "$(readlink "$_bin/muster" 2>/dev/null)" = "$_root/bin/muster" ]; then
    rm -f "$_bin/muster"
    echo "$PKG: removed $_bin/muster"
  else
    echo "$PKG: $_bin/muster is not this install's link; left alone"
  fi
}

# THE THREE QUESTIONS charon's check asks, for the reason it gives: an
# answer to "is something called muster on PATH" is satisfied as well by a
# stale copy shadowing this install as by this install. Plus a fourth:
# does the installed link actually RUN, which is what proves it finds lib/.
do_check() {
  echo "== $PKG (cross-repo survey, owed, catch-up, schedule) =="
  _want=$_bin/muster
  _got=$(command -v muster 2>/dev/null || true)
  if [ ! -e "$_want" ]; then
    bad "muster not installed ($_want)"
  elif [ "$(readlink "$_want" 2>/dev/null)" != "$_root/bin/muster" ]; then
    bad "$_want is not a link to this tree ($_root)"
  elif [ -z "$_got" ]; then
    # WARN: whether $_bin is on the CALLER'S PATH is the caller's business,
    # and an integrator checking from a non-login context has none.
    warn "muster installed at $_want but not on THIS shell's PATH"
  elif [ "$(readlink -f "$_got" 2>/dev/null)" \
       != "$(readlink -f "$_want" 2>/dev/null)" ]; then
    bad "muster on PATH is $_got, NOT the installed $_want (shadowed)"
  else
    ok "muster present, and PATH resolves to this install"
  fi
  if [ -e "$_want" ] && "$_want" help >/dev/null 2>&1; then
    ok "the installed muster runs (it found its lib/)"
  elif [ -e "$_want" ]; then
    bad "the installed muster does not run: \`$_want help\` failed"
  fi
  for _d in $DEPS_HARD; do
    if command -v "$_d" >/dev/null 2>&1; then ok "dep $_d present"
    else bad "dep $_d absent (the survey cannot run)"; fi
  done
  for _d in $DEPS_SOFT; do
    if command -v "$_d" >/dev/null 2>&1; then ok "dep $_d present"
    else warn "dep $_d absent (a verb degrades)"; fi
  done
}

_U="usage: setup.sh [install|uninstall|check|test|version]"
case "${1:-install}" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  check)     do_check; exit "$RC" ;;
  test)      exec sh "$_root/test/run" ;;
  version)   echo "$PKG $VERSION" ;;
  -h|--help|help) echo "$_U" ;;
  *) echo "$_U" >&2; exit 2 ;;
esac
