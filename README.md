# muster

Keeping many repos coherent enough to reason about.

A muster is the act of assembling a set and verifying each member is present
and correct. That is this tool's whole job, and "pass muster" is the other
half of it.

## The problem

Work spread across many small repos, on more than one machine, with shared
development standards vendored into each one, produces a class of failure
that is individually trivial and collectively expensive: every answer you
have about the set is slightly out of date, and nothing tells you which.

Each repo knows itself. Each machine knows its own checkouts. Nothing knows
the set. So:

- a checkout can be commits behind while `git status` says it is current,
  because the ref it compares against is itself stale
- a package installed from a moving pin has a dev checkout, a deployed
  clone and an origin, and all three can disagree
- a shared file vendored into fifteen repos drifts fifteen ways
- a verification that takes half an hour can be invalidated, silently, by
  someone else's commit while it runs

Every one of those is a stale read or a stale write.

## What it does

Two halves, deliberately split by what they need to run:

**Survey**, the diagnostic half: what state is this set of repos actually
in. Pure POSIX shell, no network required, no virtualenv, because this is
reached for precisely when something is broken and that is when a heavy
dependency is least likely to be there.

**Reconcile**, the mutating half: make a shared artifact agree across the
set, asynchronously, without blocking any repo. May depend on real tools,
because mutating work can demand them.

Diagnose with nothing, repair with tools.

## What it is not

- Not a release coordinator. A verification that outlives its tree needs a
  freeze, which is a human decision; the tool's job is to say the result
  is void.
- Not a monorepo emulator. It does not build, publish or version anything.
- It knows nothing about who is calling it.
- It does not enforce access boundaries. Where a kernel-level boundary
  exists, that boundary is the enforcement, and a tool honouring it by
  convention would be a soft rule standing where a hard one already is.

## Install

    ./setup.sh install      link bin/muster into ~/.local/bin
    ./setup.sh check        installed, on PATH, not shadowed, and it runs
    ./setup.sh uninstall    remove the link, only if it is this tree's

Only the command is linked; it finds `lib/` beside itself through the
link, so there is nothing else to place. This is the package contract
tackup installs through.

## Usage

    muster survey                 every repo under ~/src, as a table
    muster survey --porcelain     the same records, one line each
    muster survey --fetch         fetch first (the only network use)
    muster survey mux tackup      just these
    muster owed                   what each repo is owed (fetches first)
    muster catch-up --dry-run     what catch-up would do
    muster catch-up               fast-forward and safe-rebase the set
    muster run <profile>          run a profile and store the result
    muster report                 every profile's latest run, in one view
    muster schedule install       systemd user timers for the profiles

Exit status: 0 when every repo is ok, 1 when anything needs attention,
2 when the survey could not run at all (bad option, unreadable root or
config, no repos found).

A record's `state` is `ok`, or one of the terminal states `absent`,
`unreadable`, `not-a-repo`, `broken`, or a comma-joined list of findings:
`dirty`, `ahead`, `behind`, `no-upstream`, `upstream-gone`, `detached`,
`unborn`, `fetch-failed`, `deployed-differs`, `deployed-absent`, and the
like. `unreadable` means muster could not look; it is never reported as
absent.

`behind` is counted against the local remote-tracking ref, so it is only
as current as the last fetch, and every record carries `fetched`, the
epoch time this clone last heard from its remote (`never` if there is no
evidence it ever did). The table shows it as an age beside the count.

With `--fetch`, the outcome is read per repo from git's exit status. A
repo whose fetch failed is `fetch-failed`, its `ahead` and `behind` are
`-` rather than numbers from the stale ref, and git's reason is printed
on stderr. A fleet mixing ssh and https remotes, surveyed from a session
with no ssh agent, fails exactly the ssh half, so this is the normal
failure, not an edge case.

### owed

For each repo, what it is owed to agree with its origin, and with the
canonical copy of each vendored file it carries. It fetches first,
because every answer rests on the remote-tracking ref, and changes
nothing else. `--no-fetch` judges the refs as they are; each record
still carries the fetch time it was judged from.

    nothing    in agreement
    pull       behind and clean: a fast-forward
    rebase     diverged, and no file changed on both sides (renames
               count as both paths), and no local merge to flatten
    push       ahead
    escalate   diverged on a shared file, or over a local merge: a
               human decides. `overlap` names the first shared file
    skip       behind with uncommitted work, or a vendored copy being
               edited: never touched
    reseed     a vendored copy differs from the canonical, and origin
               does not carry the canonical either
    redeploy   the declared deployed clone does not match origin
    unknown    something could not be established: the `state` says
               what (fetch-failed, unreadable, no-upstream, ...)

A vendored copy that differs while origin ALREADY carries the canonical
is a pull, never a re-seed, because re-seeding would commit what the
remote already has. And a canonical whose own checkout is dirty, ahead,
behind or unfetchable is not trusted: every copy of it reads `unknown`,
with a warning naming it. One problem gets one row: when the canonical's
repo is in the same run, ITS row owes the fix (usually a pull) and the
copies' `unknown` does not count against their repos; only when nothing
else would show it (the canonical is missing, or its repo is not in the
run) does an unknown copy make its repo `unknown`.

Record: `name owed state ahead behind fetched overlap artifacts path`,
with `artifacts` a comma list of `<relpath>:<verdict>`.

### catch-up

Acts on owed's `pull` and `rebase` verdicts and nothing else. It fetches,
judges each repo with owed's own computation, and then:

- `pull`: `git merge --ff-only` to the fetched upstream, then checks HEAD
  is exactly that commit.
- `rebase`: a non-interactive rebase onto the upstream, then a proof:
  the local commits' diff must be byte-identical before and after. A
  rebase that fails is aborted; one that altered the local work is reset
  to the exact commit it started from. Both are checked, not assumed.

The repo holding each canonical is caught up FIRST, when it is in the
set, so one run can pull a stale canonical and then judge every copy
against it; without that, a behind canonical makes every copy `unknown`
until a second run.

Immediately before acting it re-checks that HEAD, the upstream ref and
the clean tree are still what the verdict saw; if another session moved
any of them, the repo is reported `changed-underfoot` and left alone.

It NEVER pushes, and never touches a repo owed `skip`, `escalate`,
`unknown`, `reseed` or `redeploy`. Each repo it acted on is judged again
afterwards, so the `remaining` field says what is still owed (a rebased
repo still owes its `push`).

Record: `name action result from to owed remaining path`. Exit 0 only
when every repo ends owing nothing and every action succeeded.
`ABORT-FAILED` or `REVERT-FAILED` in the result column means a repo was
left mid-operation and needs a human now.

### Profiles, run and report

A profile names a verb and how often it should run:

    profile <name> <verb> <interval>     verb: survey, owed or catch-up
                                         interval: 30m, 2h, 1d

With no profile declared there is one default, observe-only: `owed`,
hourly. Which verb runs unattended is the integrator's choice per
profile; nothing writes to a working tree unless a profile says
catch-up.

`muster run <profile>` runs the verb and stores its records, stderr and
a meta file (`profile verb interval started finished exit host`) under
`$MUSTER_STATE_DIR` (default `~/.local/state/muster/<profile>/`): a
`latest.*` set swapped in whole, and a history pruned to `$MUSTER_KEEP`
(default 48). A lock keeps a timer and a manual run of one profile from
overlapping; a lock left by a dead process is taken over. The verb's
exit passes through.

`muster report` shows every profile's latest run: its age, and a status
of `ok`, `attention`, `failed`, `never` (no stored run) or `stale` (older
than twice its interval, so whatever should run it has stopped). Below
that, each profile's rows that need attention, drawn by the verb's own
renderer. Exit 0 only when every profile is `ok`.

`MUSTER_NOTIFY`, if set, gets each run's STATE in the fleet's notifier
protocol (intervention-required's, which charon also speaks):
`flag muster-<profile> "<message>"` while rows need attention or the run
could not run, `clear muster-<profile>` once none do. A flag is a
standing fact, so raising it again is idempotent, and a lost
notification corrects itself on the next run. A notifier that is set but
not on PATH is reported on stderr, never skipped in silence.

### schedule

`muster schedule install|check|remove` turns the profiles into systemd
user units (`~/.config/systemd/user/muster-<profile>.{service,timer}`),
generated, never hand-edited:

- `install` writes each unit only if its content changed, bakes the
  config path (and `MUSTER_ROOT`, `MUSTER_STATE_DIR`, `MUSTER_NOTIFY`,
  `MUSTER_KEEP` when set) into the service, the notifier as an ABSOLUTE
  path since a unit's PATH is not the installing shell's (one that does
  not resolve is refused), removes units for profiles
  no longer declared, reloads the user manager and enables every timer.
- `check` changes nothing and lists `missing`, `differs`, `disabled`,
  `inactive` and `orphan` units, exit 1 on any: an integrator's check
  calls it, and its apply calls `install`.
- `remove` disables and deletes every unit muster generated.

A unit is muster's only if its first line says so; a hand-written
`muster-*.timer` is never reported or removed. Profile names are word
characters only, since each becomes a unit name. Without systemd it
fails, saying to call `muster run <profile>` from the box's own
scheduler.

### The porcelain

One line per repo, space-separated `key=value`, every key on every line,
`-` where a value does not apply, in this order:

    name state branch head upstream upstream_head ahead behind fetched
    modified untracked deployed expect path

`name` and `path` are percent-encoded (`%`, space, tab, newline), so no
value can contain the separator. The table is rendered from these same
records, never computed separately.

### Configuration

Optional, at `$MUSTER_CONFIG` or `~/.config/muster/repos`. Without it,
muster surveys every git repo one level under `~/src`.

    root <dir>               where discovery looks
    repo <name> [<path>]     declare the set; any `repo` line turns
                             discovery off. path defaults to root/name
    deployed <name> <path>   a deployed clone of <name>, compared with
                             origin: the third head
    origin <glob>            discovery takes only repos whose origin URL
                             matches one of these (e.g. `*jello-d/*`): a
                             third-party clone is left out by rule, with
                             no per-box list. An unreadable directory
                             stays in (its origin cannot be read), and a
                             repo named on the command line is surveyed
                             whatever its origin
    expect <name> <state>    <name> is DECLARED unreadable or absent:
                             reported, marked (expected), and does not
                             fail the run. Any other state is a loud
                             `expect-mismatch`: a sealed tree that turns
                             readable means its wall has a hole
    artifact <canonical> <relpath>... [requires <relpath>...]
                             a vendored file for owed to judge. A repo
                             has adopted it if it carries it at one of
                             the relpaths, AND one of the `requires`
                             paths when given (a repo with a hook of its
                             own has not adopted the vendored hook)

`MUSTER_ROOT` overrides `root`. An unknown directive is an error, not a
skipped line.

## Status

`survey`, `owed`, `catch-up`, `run`, `report` and `schedule` are
implemented. Re-seeding vendored
files (owed's `reseed`) is not: it has been needed zero times so far,
and copier was verified by hand and set aside (see
`docs/requirements.md`). Running catch-up on a schedule is the
integrator's decision.

`test/run` runs the suite: the vendored conventions check, shellcheck,
and `test/survey.t`, `owed.t`, `catchup.t`, `profiles.t` and
`schedule.t`, which build real git repositories in a scratch directory
rather than stubbing git. Only systemctl is stubbed, and the unit
directory is proven to be inside the scratch directory first.
