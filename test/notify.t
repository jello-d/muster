#!/bin/sh
# test/notify.t - the flags muster raises are cleared once they are no
# longer valid. Each flag is RECORDED (with the config that raised it)
# and swept when its profile is no longer declared; each carries a
# --recheck that the notifier's own reconcile runs, with an empty
# environment, and `muster flag-holds` answers it from stored state.
#
# Prints `ok   notify (N checks)` or `FAIL notify:` and every failure.
set -u

H_NAME=notify
# shellcheck source=SCRIPTDIR/harness_lib
. "$(dirname -- "$0")/harness_lib"

export MUSTER_STATE_DIR="$_T/state"
S=$_T/state
C=$_T/cfg
mkdir -p "$C"
cli() {
  OUT=$("$MUSTER" "$@" 2>"$_T/err" </dev/null)
  RC=$?
  ERR=$(cat "$_T/err")
}

# A notifier that keeps flags as files, like intervention-required: the
# message in <key>, a --recheck in <key>.recheck, and `reconcile` runs
# each recheck with NOTHING in its environment but PATH, clearing on
# exit 1 (resolved) and keeping on 0 (needed) or 2+ (cannot say).
F=$_T/flags
mkdir -p "$F"
cat > "$_T/notifier" <<NOTIFIER
#!/bin/sh
case \$1 in
  flag) shift
    rm -f '$F'/"\$1.recheck" 2>/dev/null
    if [ "\$1" = --recheck ]; then _r=\$2; shift 2
      printf '%s\n' "\$_r" > '$F'/"\$1.recheck"; fi
    printf '%s\n' "\$2" > '$F'/"\$1" ;;
  clear) rm -f '$F'/"\$2" '$F'/"\$2.recheck" ;;
  reconcile)
    for _f in '$F'/*.recheck; do
      [ -f "\$_f" ] || continue
      _k=\${_f##*/}; _k=\${_k%.recheck}
      env -i PATH="\$PATH" sh -c "\$(cat "\$_f")" >/dev/null 2>&1
      [ "\$?" != 1 ] || rm -f '$F'/"\$_k" "\$_f"
    done ;;
  *) exit 9 ;;
esac
NOTIFIER
chmod +x "$_T/notifier"
export MUSTER_NOTIFY="$_T/notifier"
flags() {
  for _f in "$F"/*; do
    case $_f in *.recheck) ;; *) [ ! -f "$_f" ] || printf '%s ' "${_f##*/}" ;;
    esac
  done
}

mkrepo one
mkrepo two
printf 'profile old owed - one\nprofile keep owed - two\n' | h_cfg "$C/a"
export MUSTER_CONFIG="$C/a"

# === a flag is raised with a recheck, and recorded ==========================
upstream_moves one
cli run old
expect_rc 1 "old: one is behind, attention"
assert "the flag is raised" has "$(flags)" "muster-old"
assert "with a recheck naming flag-holds" \
  has "$(cat "$F/muster-old.recheck")" "'flag-holds' 'muster-old'"
assert "the recheck carries the config" \
  has "$(cat "$F/muster-old.recheck")" "'MUSTER_CONFIG=$C/a'"
assert "it is recorded, with the config that raised it" \
  test "$(cat "$S/notified/muster-old")" = "$C/a"
cli flag-holds muster-old
expect_rc 0 "flag-holds: still needed"

# === the notifier's reconcile: kept while needed, cleared once resolved ====
"$_T/notifier" reconcile
assert "reconcile keeps a flag still needed (empty env)" \
  has "$(flags)" "muster-old"
g "$ROOT/one" pull --ff-only
cli run keep            # some OTHER profile runs; old is not re-run
"$_T/notifier" reconcile
assert "a fix made by hand: kept until old runs again" \
  has "$(flags)" "muster-old"
cli run old
expect_rc 0 "old: clean"
assert "a clean run clears its flag" lacks "$(flags)" "muster-old"
assert "and drops its record" test ! -e "$S/notified/muster-old"
cli flag-holds muster-old
expect_rc 1 "flag-holds: resolved"

# === a profile renamed away: its flag no longer valid, and cleared ==========
upstream_moves one
cli run old
assert "old flagged again" has "$(flags)" "muster-old"
printf 'profile new owed - one\nprofile keep owed - two\n' | h_cfg "$C/a"
cli flag-holds muster-old
expect_rc 1 "flag-holds: a profile no longer declared is resolved"
cli check
assert "check: the stale flag is drift" \
  has "$OUT" "drift  flag       muster-old: raised by muster and no longer"
"$_T/notifier" reconcile
assert "the notifier's own reconcile clears it (recheck)" \
  lacks "$(flags)" "muster-old"
# The same, through muster's own record, with no reconcile at all.
printf 'profile old owed - one\nprofile keep owed - two\n' | h_cfg "$C/a"
cli run old
assert "old flagged once more" has "$(flags)" "muster-old"
printf 'profile new owed - one\nprofile keep owed - two\n' | h_cfg "$C/a"
cli run keep
assert "the next run of ANY profile sweeps it" lacks "$(flags)" "muster-old"
assert "and its record" test ! -e "$S/notified/muster-old"
cli check
assert "check: nothing stale left" lacks "$OUT" "flag       muster-old"

# === schedule install sweeps too (where a rename is applied) ================
h_stub_systemctl
printf 'profile old owed - one\n' | h_cfg "$C/a"
cli run old
printf 'profile new owed - one\n' | h_cfg "$C/a"
cli schedule install
assert "schedule install clears a renamed profile's flag" \
  lacks "$(flags)" "muster-old"

# === another config's flags are judged against THAT config ==================
printf 'profile old owed - one\n' | h_cfg "$C/a"
cli run old
printf 'profile other owed - two\n' | h_cfg "$C/b"
MUSTER_CONFIG=$C/b cli run other
assert "an ad hoc run under another config leaves this one's flags" \
  has "$(flags)" "muster-old"
rm -f "$C/a"
MUSTER_CONFIG=$C/b cli run other
assert "a flag whose config is gone is cleared" lacks "$(flags)" "muster-old"
printf 'profile old owed - one\n' | h_cfg "$C/a"

# === the config flag ========================================================
cli flag-holds muster.config
expect_rc 1 "flag-holds muster.config: nothing placed, resolved"
cli flag-holds something-else
expect_rc 2 "flag-holds: a flag that is not muster's: cannot say"
printf 'bogus line\n' > "$C/broken"
MUSTER_CONFIG=$C/broken cli flag-holds muster-old
expect_rc 2 "flag-holds: an invalid config: cannot say (kept)"

# === no reachable notifier: a stale record is a FAULT =======================
cli run old
printf 'profile new owed - one\n' | h_cfg "$C/a"
MUSTER_NOTIFY=$_T/no-such-notifier cli check
expect_rc 3 "stale flag, notifier unreachable: a fault"
assert "named" has "$OUT" "fault  flag       muster-old"
cli check
expect_rc 1 "with the notifier back: drift again"

# === a failing notifier records nothing ===================================
rm -f "$S/notified/muster-new"
printf '#!/bin/sh\nexit 1\n' > "$_T/badnotifier"
chmod +x "$_T/badnotifier"
upstream_moves one
MUSTER_NOTIFY=$_T/badnotifier cli run new
assert "a flag that failed is not recorded" test ! -e "$S/notified/muster-new"

# === a value a recheck cannot quote: flagged, without one ===================
mkdir -p "$_T/it's"
cp "$C/a" "$_T/it's/cfg"
MUSTER_CONFIG="$_T/it's/cfg" cli run new
assert "flagged even so" has "$(flags)" "muster-new"
assert "but with no recheck it could not quote" \
  test ! -e "$F/muster-new.recheck"

h_verdict
