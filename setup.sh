#!/bin/sh
# setup.sh - install / uninstall / check / test muster. The single entry
# point a consumer or provisioning layer uses (tackup's pkg contract).
#
#   ./setup.sh install     copy bin/ and lib/ into the payload
#                          (~/.local/share/muster), swapped in whole,
#                          and link ~/.local/bin/muster into it
#   ./setup.sh uninstall   remove that link and the payload, if ours
#   ./setup.sh check       installed as a payload matching this tree,
#                          reachable, not shadowed, nothing linked into
#                          the clone, and it RUNS; [OK]/[FAIL]/[WARN]
#                          markers, exit 1 on a FAIL
#   ./setup.sh paths       where everything lives, `<name> TAB <path>`
#   ./setup.sh test        run the in-repo suite (test/run)
#   ./setup.sh version     the packaged version
#
# POSIX sh, non-privileged: muster reads the user's own checkouts and
# nothing root touches, so it lives in ~/.local (the house install-
# placement rule). Honors PREFIX, XDG_BIN_HOME and XDG_DATA_HOME so a
# test sandboxes it.
#
# A PAYLOAD, NOT LINKS INTO THIS TREE (the fleet's payload-tree layout,
# 2026-10-01). This tree is a clone a provisioner moves on every sweep, so
# an install linked into it changes under a running muster and dies with
# the clone. bin/muster resolves its own symlink and reads ../lib, so bin/
# and lib/ are copied together into one payload and the link points
# there. Timers are NOT installed here: they are generated from the
# integrator's profiles by `muster schedule install`.
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
_shr=${XDG_DATA_HOME:-$PREFIX/share}
_pay=$_shr/$PKG
# What the payload carries: every directory bin/muster reads.
_SHIPPED="bin lib"
# Written first into every payload this script builds. Nothing is ever
# deleted from a directory that does not carry it.
_MARK=.muster-payload
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

# _pay_rm <dir>: remove a payload this script built, file by file. NEVER
# `rm -rf` on a variable (the house rule, paid for by a harness that
# deleted its own checkout): the path must be one of the three payload
# names, the payload root must have its shape and lie outside this tree,
# and the directory must be real and carry the marker. Anything else is
# refused loudly, never guessed at.
_pay_rm() {
  [ -e "$1" ] || [ -L "$1" ] || return 0
  case $_pay in
    "$_root"|"$_root"/*)
      echo "$PKG: payload $_pay is inside this tree; refusing" >&2
      return 1 ;;
    /?*/"$PKG") ;;
    *) echo "$PKG: payload root [$_pay] has no usable shape" >&2; return 1 ;;
  esac
  case $1 in
    "$_pay"|"$_pay".new|"$_pay".old) ;;
    *) echo "$PKG: refusing to remove $1: not a payload path" >&2
       return 1 ;;
  esac
  if [ -L "$1" ] || [ ! -d "$1" ] || [ ! -f "$1/$_MARK" ]; then
    echo "$PKG: refusing to remove $1: not a payload this script" \
      "built (no $_MARK)" >&2
    return 1
  fi
  find "$1" ! -type d ! -name "$_MARK" -exec rm -f {} + \
    && rm -f "$1/$_MARK" \
    && find "$1" -depth -type d -exec rmdir {} +
}

# _pay_stage: build the new payload beside the live one, PROVE it runs
# from there (it must find its own lib/), and only then swap it in. A
# failure anywhere leaves the live payload as it was.
_pay_stage() {
  _s_new=$_pay.new _s_old=$_pay.old
  _pay_rm "$_s_new" && _pay_rm "$_s_old" || return 1
  mkdir -p "$_s_new" && : > "$_s_new/$_MARK" || return 1
  for _s_d in $_SHIPPED; do
    cp -R "$_root/$_s_d" "$_s_new/$_s_d" || return 1
  done
  if ! "$_s_new/bin/muster" help >/dev/null 2>&1; then
    echo "$PKG: the staged payload does not run; live one untouched" >&2
    _pay_rm "$_s_new"
    return 1
  fi
  if [ -e "$_pay" ] || [ -L "$_pay" ]; then
    if [ -L "$_pay" ] || [ ! -f "$_pay/$_MARK" ]; then
      echo "$PKG: $_pay exists and was not built by this script;" \
        "left alone" >&2
      _pay_rm "$_s_new"
      return 1
    fi
    mv "$_pay" "$_s_old" || return 1
  fi
  if ! mv "$_s_new" "$_pay"; then
    [ ! -d "$_s_old" ] || mv "$_s_old" "$_pay"
    return 1
  fi
  _pay_rm "$_s_old"
}

do_install() {
  _pay_stage || exit 1
  mkdir -p "$_bin"
  ln -sfn "$_pay/bin/muster" "$_bin/muster"
  echo "$PKG: payload at $_pay, muster linked into $_bin"
}

# Removes the link if it is ours, now OR from the era of links into the
# clone, and the payload if this script built it.
do_uninstall() {
  case $(readlink "$_bin/muster" 2>/dev/null || :) in
    "$_pay/bin/muster"|"$_root/bin/muster")
      rm -f "$_bin/muster"
      echo "$PKG: removed $_bin/muster" ;;
    *) echo "$PKG: $_bin/muster is not this install's link; left alone" ;;
  esac
  if [ -e "$_pay" ] || [ -L "$_pay" ]; then
    _pay_rm "$_pay" || exit 1
    echo "$PKG: removed the payload $_pay"
  fi
}

# _ck_payload: a real directory this script built, holding exactly what
# this tree ships. A payload is a COPY, so it can drift from the tree; the
# diff is the detector, and install is the repair.
_ck_payload() {
  if [ -L "$_pay" ] || [ ! -d "$_pay" ]; then
    bad "no payload at $_pay (a real directory)"
  elif [ ! -f "$_pay/$_MARK" ]; then
    bad "$_pay was not built by this setup.sh (no $_MARK)"
  else
    for _p_d in $_SHIPPED; do
      if ! diff -r "$_root/$_p_d" "$_pay/$_p_d" >/dev/null 2>&1; then
        bad "the payload's $_p_d/ differs from this tree (re-run install)"
        return 0
      fi
    done
    ok "payload at $_pay, a real directory matching this tree"
  fi
}

# _ck_clone_links: NOTHING under the prefix may resolve into this tree,
# the clone a provisioner moves under a running install. -lname matches
# the link text, which is how every link this script ever wrote spelled
# it, and stays fast over thousands of links.
_ck_clone_links() {
  [ -d "$PREFIX" ] || return 0
  _l_in=$(find "$PREFIX" -type l \( -lname "$_root" -o -lname "$_root/*" \) \
    2>/dev/null || :)
  if [ -z "$_l_in" ]; then
    ok "nothing under $PREFIX links into this tree"
    return 0
  fi
  printf '%s\n' "$_l_in" | while IFS= read -r _l_p; do
    printf '  %s[FAIL]%s %s links into this tree (%s)\n' "$_R" "$_O" \
      "$_l_p" "$_root"
  done
  RC=1
}

# THE QUESTIONS charon's check asks, for the reason it gives: an answer
# to "is something called muster on PATH" is satisfied as well by a stale
# copy shadowing this install as by this install. Plus: is the payload
# the one this tree ships, does the installed link actually RUN (which
# proves it finds lib/), and is nothing left pointing into the clone.
do_check() {
  echo "== $PKG (cross-repo survey, owed, catch-up, schedule) =="
  _ck_payload
  _want=$_bin/muster
  _got=$(command -v muster 2>/dev/null || true)
  if [ ! -e "$_want" ]; then
    bad "muster not installed ($_want)"
  elif [ "$(readlink "$_want" 2>/dev/null)" != "$_pay/bin/muster" ]; then
    bad "$_want is not a link into the payload ($_pay)"
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
  _ck_clone_links
  for _d in $DEPS_HARD; do
    if command -v "$_d" >/dev/null 2>&1; then ok "dep $_d present"
    else bad "dep $_d absent (the survey cannot run)"; fi
  done
  for _d in $DEPS_SOFT; do
    if command -v "$_d" >/dev/null 2>&1; then ok "dep $_d present"
    else warn "dep $_d absent (a verb degrades)"; fi
  done
}

do_paths() {
  _p_cf=${XDG_CONFIG_HOME:-$HOME/.config}/muster/repos
  _p_st=${XDG_STATE_HOME:-$HOME/.local/state}/muster
  printf 'bin\t%s\n'     "$_bin/muster"
  printf 'payload\t%s\n' "$_pay"
  printf 'config\t%s\n'  "${MUSTER_CONFIG:-$_p_cf}"
  printf 'state\t%s\n'   "${MUSTER_STATE_DIR:-$_p_st}"
}

_U="usage: setup.sh [install|uninstall|check|paths|test|version]"
case "${1:-install}" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  check)     do_check; exit "$RC" ;;
  paths)     do_paths ;;
  test)      exec sh "$_root/test/run" ;;
  version)   echo "$PKG $VERSION" ;;
  -h|--help|help) echo "$_U" ;;
  *) echo "$_U" >&2; exit 2 ;;
esac
