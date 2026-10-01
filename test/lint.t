#!/bin/sh
# test/lint.t - shellcheck over every shell file muster ships or tests with.
#
# The file list is DERIVED from what git tracks, by shebang or by the
# `shellcheck shell=` directive a sourced lib carries, never by suffix: a
# suffix selector silently shrinks when a file is renamed to a bare name.
#
# test/conventions.t and .githooks/pre-commit are excluded BY NAME: both
# are vendored from shared-notes and edited only there, so a finding in
# either belongs to the canonical copy.
set -u

ROOT=$(git -C "$(dirname -- "$0")" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "FAIL lint: not a git repo"; exit 1; }
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "skip lint: shellcheck is not installed"
  exit 0
fi

files=$(cd "$ROOT" && git ls-files | while IFS= read -r f; do
  case $f in test/conventions.t|.githooks/pre-commit) continue ;; esac
  [ -f "$f" ] || continue
  first=$(head -n 1 -- "$f")
  case $first in
    '#!/bin/sh'*|'#!/usr/bin/env sh'*|'# shellcheck shell=sh'*)
      printf '%s\n' "$f" ;;
  esac
done)
[ -n "$files" ] || { echo "FAIL lint: found no shell files to check"; exit 1; }

n=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
# shellcheck disable=SC2086  # one path per word; git paths here have no spaces
if out=$(cd "$ROOT" && shellcheck -x -s sh $files 2>&1); then
  echo "ok   lint ($n files)"
else
  printf 'FAIL lint:\n%s\n' "$out"
  exit 1
fi
