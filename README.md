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

    ./setup.sh install      copy bin/ and lib/ into ~/.local/share/muster,
                            link ~/.local/bin/muster into that copy
    ./setup.sh check        the copy matches this tree, on PATH, not
                            shadowed, nothing links into this tree, runs
    ./setup.sh uninstall    remove the link and the copy, if they are ours
    ./setup.sh paths        where the command, payload, config, state live

The installed copy (the payload) is built beside the live one, proven to
run, then swapped in whole, so the install outlives the tree it came
from and never changes under a running muster. The command finds `lib/`
beside itself through the link. This is the package contract tackup
installs through.

## Usage

    muster survey                 every repo under ~/src, as a table
    muster survey --porcelain     the same records, one line each
    muster survey --fetch         fetch first (the only network use)
    muster survey mux tackup      just these
    muster owed                   what each repo is owed (fetches first)
    muster catch-up --dry-run     what catch-up would do
    muster catch-up               fast-forward and safe-rebase the set
    muster resolve --dry-run      what resolve would do, and what needs you
    muster resolve                everything safe, then what needs you
    muster run <profile>          run a profile and store the result
    muster report                 every profile's latest run, in one view
    muster schedule install       systemd user timers for the profiles
    muster check                  is the profile policy coherent here?
    muster stamp tackup > s       record the tree before a long run
    muster stamp check --fetch s  does the result still describe it?

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

Record: `name action result from to owed remaining state fetched path`.
Exit 0 only
when every repo ends owing nothing and every action succeeded.
`ABORT-FAILED` or `REVERT-FAILED` in the result column means a repo was
left mid-operation and needs a human now.

### resolve: everything safe, then what needs you

    muster resolve [--dry-run] [name...]

The one command to run when something is red. In order:

1. **repos**: `catch-up`, the canonical first, then fast-forward, or
   rebase where no file changed on both sides.
2. **config**: `place` (box-wide, so skipped when repos are named).
3. **refresh**: every profile is re-run, so `report` and the notifier
   say what is true now rather than what the last timer saw.
4. **needs you**: read fresh, after acting, one line each with the
   exact next command.

It adds no action of its own: each step is the verb above, so resolve
cannot drift from them. It holds the box lock while acting, so a timer
cannot act on the same repos mid-way. It NEVER pushes (an unpushed
commit may be another session's work), merges by hand, touches a dirty
tree, folds a live edit into the source, decides a conflict or clears a
displaced edit: those are the list. Exit 0 nothing needs you, 1
something does, 2 a step could not run.

    push         unpushed commits: review, then git -C <repo> push
    escalate     both sides changed the same files: merge by hand
    skip         uncommitted work, and behind: commit or stash, resolve
    unknown      could not fetch (locked keyring, no agent): log in,
                 or use ssh -A, then resolve
    reseed       a vendored copy differs: the integrator's notes sweep
    redeploy     a deployed clone differs: the integrator's pin sweep
    merge-back   a live edit not in the source: review (muster where),
                 then muster merge-back <path>, and commit
    capture      an application's file not in the source: review, then
                 muster capture <path>, and commit
    conflict     changed live AND in the source: decide which wins
    displaced    a repo-owned edit kept aside: salvage it, then
                 muster displaced clear <run> <path>
    source-link, foreign, linked-dir, shadowed
                 a shape muster will not act on: fix the source or link

WHEN THE BANNER FIRES: `muster report` shows what the timer saw (instant,
no network); `muster resolve --dry-run` shows what can be done and what
cannot; `muster resolve` does it. A fix made by hand shows in `report`
after the next run, and until then report names the repos that moved
and the command to refresh: `muster run <profile>`, or `resolve`.
`muster check` is the deeper question, whether muster itself is healthy
here, and is where config faults show without a run.

### Profiles, run and report

A profile is a POLICY OVER A SET OF REPOS: a verb, how often, and
which repos.

    driver <systemd|external|manual>
    notify </absolute/path>
    profile <name> <verb> <interval> [driver=<d>] [<selector>...]
        verb       survey, owed or catch-up
        interval   30m, 2h, 1d; or - for a manual profile
        driver     WHO RUNS it: muster's own timers (systemd), the
                   integrator's scheduler calling `muster run` (external),
                   or nobody, on demand (manual). Per profile, else the
                   config's `driver` line
        selector   a repo name, or /ERE/ matched against the WHOLE name;
                   none means the whole set

    profile watch  owed     1h                   # everything, observed
    profile canon  catch-up 15m shared-notes     # one repo, kept current
    profile quiet  catch-up 2h  /h.*/ charon     # a group, by rule

The driver is the user's INTENT, and `muster check` squares it against
what is here. With no `driver` line, profiles are `manual`: run on
demand, never scheduled, never stale. Nothing is put on a timer unless
the config says so.

ACTING profiles (catch-up) may not select the same repo: two could act on
it at once. `run` and `schedule install` refuse an overlap; observe-only
profiles overlap freely. A profile whose selectors expand to nothing
fails its run rather than falling back to the whole set.

With no profile declared there is one default, observe-only: `owed`,
hourly. Which verb runs unattended is the integrator's choice per
profile; nothing writes to a working tree unless a profile says
catch-up.

`muster run <profile>` runs the verb and stores its records, stderr and
a meta file (`profile verb interval started finished exit host`) under
`$MUSTER_STATE_DIR` (default `~/.local/state/muster/<profile>/`): a
`latest.*` set swapped in whole, and a history pruned to `$MUSTER_KEEP`
(default 48). ONE RUN AT A TIME ON A BOX: `run` waits for a box-wide
lock (up to `$MUSTER_RUN_WAIT` seconds, default 600), because profiles
installed together fire together, and a catch-up pulling a repo while
another profile is reading it yields a report about two different
moments. A wait that runs out is stored as a run that did not run; a
lock left by a dead process is taken over. The verb's exit passes
through.

`muster report` shows every profile's latest run: its age, and a status
of `ok`, `attention`, `failed`, `never` (no stored run) or `stale` (older
than twice its interval, so whatever should run it has stopped). For a
systemd-driven profile an old run is NOT stale while systemd itself has
the timer due within one interval and the service's last result was
success: timers count awake time only, so after a suspend the wall clock
runs ahead of them by exactly the sleep. Below
that, each profile's rows that need attention, drawn by the verb's own
renderer. Exit 0 only when every profile is `ok`.

A stored run is what its timer SAW. Each run also records every repo's
HEAD and upstream as it left them, and `report` compares: a repo that
has moved since (a pull, a push, a commit, a fetch) is named in a footer
with the command that makes the report current, `muster run <profile>`,
or `muster resolve` for all of them. Uncommitted edits do not count, or
every repo someone is working in would read changed all day. A hint,
never a failure: the exit is unchanged. Porcelain carries it as
`moved=<repo,...>` or `moved=-`.

The notifier (`notify </absolute/path>` in the config, or
`$MUSTER_NOTIFY`, which overrides it) gets each run's STATE in the fleet's
notifier
protocol (intervention-required's, which charon also speaks):
`flag muster-<profile> "<message>"` while rows need attention or the run
could not run, `clear muster-<profile>` once none do. A flag is a
standing fact, so raising it again is idempotent, and a lost
notification corrects itself on the next run. A notifier that is set but
not on PATH is reported on stderr, never skipped in silence. The CONFIG's
notifier must be an absolute path: a bare name resolves through each
caller's PATH, and a timer, a cron job or a plain `ssh` lacks the
`~/bin` a login shell has, so the answer depended on who asked. `check`
calls a bare name (or a path that is not executable) a fault, and
`schedule install` refuses it. The environment override may be a name,
since whoever sets it resolves it where they are.

### check

`muster check` is the one comprehensive check: is all well with muster
on THIS box, judged against what was DECLARED? It runs no verb. It lists
each profile with its driver and its repos, then every finding, tagged
by the remedy it wants:

    drift   `muster schedule install` repairs it: a unit missing,
            differing, disabled, inactive, an orphan, or `unwanted`
            (present for a profile not driven by systemd)
    fault   no install repairs it: overlapping acting profiles, a
            literal selector that is not a repo here, an empty
            selection, an incoherent profile (an interval nothing will
            honour, or a driven profile with none), systemd wanted and
            absent, or runs the intent promises that are not happening:
            `stale`, `never`, `failed`
    note    shown, never counted: a pattern matching nothing here, an
            undeclared driver

Exit: **0** all well, **1** drift only, **3** any fault (it outranks
drift), **2** an invalid config. An integrator maps 1 to its apply and 3
to a fault, so its check never reports as repairable what its apply
cannot repair. A run is not overdue until the intent is twice the
interval old (dated from the timer, or before one exists from the
config), so writing the config, installing and checking converges.
Whether repos need ATTENTION is not judged here: that is the fleet's
state, which `report` and the notifier carry.

### stamp (R11)

A verification that takes longer than the interval between other
people's commits can finish green about a tree that no longer exists.
muster cannot prevent that (only a freeze can, and that is a human's
call); it makes it detectable. Take a stamp before, check it after:

    muster stamp [--fetch] [name...]  > before.stamp
    ... the long verification ...
    muster stamp check [--fetch] before.stamp

A stamp records, per repo, HEAD, a fingerprint of everything uncommitted
(tracked changes staged or not, plus untracked, unignored files and
their contents), and the upstream head. The check answers per repo:

    holds        nothing recorded has changed
    moved        HEAD is not the stamped commit
    changed      HEAD is, the working tree is not
    superseded   origin's head is not contained in what was tested: it
                 moved during the run, or the checkout was already
                 behind when stamped. Ahead of origin (your own release
                 commits) is fine. Only as current as the last fetch;
                 use --fetch, both times
    gone         absent or unreadable now, and was not then

Exit 0 when every repo holds, 1 when any does not, 2 when the stamp is
empty, missing or not a stamp: an unusable stamp never reads as "all
holds". For the same reason `stamp` refuses a NAMED repo that is not
there: a typo would record "absent", and its check would hold forever,
guarding nothing. With no names it stamps the whole set, which can only
void more often, never less. An untracked scratch file left in a
checkout voids its stamp: the gate runs against the working tree, so
that is the stamp working, not a false alarm. The stamp carries its own
paths, so it is checked against the tree it named whatever the config
says later. Both are read-only.

### placement (config as copies)

Requirements and reasoning: `docs/placement.md`. The integrator declares
root pairs and per-file overrides:

    place <source-root> <dest-root> <user-editable|repo-owned|app-owned>
    policy <dest-path> <user-editable|repo-owned|app-owned>
    capture <dest-dir>     an application creates files here (P10)

Each file has three versions: the source (the integrator's working tree;
tracked and new files, never gitignored ones), the live copy, and the
baseline, a sparse mirror under `<state>/root/<absolute path>` whose
files ARE what was last placed, content and mode. Nothing else is
stored. The commands:

    muster placed [--porcelain] [path...]    each file's verdict
    muster place [--dry-run] [path...]       place what is owed
    muster merge-back [--dry-run] [path...]  live edits into the source
    muster capture [--dry-run] [path...]     an app's work into the source
    muster where <path>                      source <-> destination
    muster displaced [list | clear ...]      repo-owned edits kept aside

Verdicts: `in-sync`, `new`, `missing` (deleted live: comes back),
`place`, `converged`, `migrate` (a symlink into its own source becomes a
copy), `migrate-dir` (a whole-directory link into its own source,
the destination root itself included, becomes a real directory; files
the link showed that are not source are kept as unmanaged copies and
named; refused, with the link left as it
was, while it shows a symlink, which a copy would drop), `merge-back`,
`capture`,
`displace`, `orphan`, `app-held`, `conflict`, `shadowed`, `foreign`,
`linked-dir` (a directory link to anywhere else: never touched),
`source-link` (the source is a symlink: never placed, a fault naming
it), `read-only`, `unreadable`, `no-source`.

No edit is lost under any policy. `place` never overwrites a
user-editable live edit (that is a merge-back or a conflict); it
overwrites a repo-owned one only after DISPLACING it to
`<state>/displaced/<run>/<path>`, verified, kept until a person clears
it, and a `check` fault until then. `merge-back` writes into the source
working tree only, never commits, and leaves alone a source file git
reports as modified. Every write goes to a temp file that is verified
BEFORE it is renamed into place, and the baseline moves only after the
live write is verified. A source root that is missing, unreadable or
empty places and removes NOTHING. `check` reports placement drift (what
`place` repairs, which an apply runs) and faults (conflicts, displaced
edits, PENDING MERGE-BACKS, read-only destinations, a missing source).
Merge-back is a deliberate, explicit step and never part of an apply,
so a pending one needs a person: until it runs, the edit is not in the
source and no other machine will get it.

### schedule

`muster schedule install|check|remove` turns the profiles into systemd
user units (`~/.config/systemd/user/muster-<profile>.{service,timer}`),
generated, never hand-edited:

- The unit runs THE INSTALLED muster, the one on PATH followed to the
  real file (falling back to the running copy only where none is
  installed), so an install or a check from a dev checkout never
  repoints the live timers at that tree, and callers with and without
  the bin link on PATH bake the same unit.
- The service declares `SuccessExitStatus=1`: a run that found repos
  needing attention has reported, not failed, so the unit stays green;
  a run that could not run (exit 2) still fails it.
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

PLACEMENT BUILT through increment 2: leaf files, whole-directory links
(migrated), and capture directories; requirements in
`docs/placement.md`. Not yet: `~/bin`, overlay layers, the three-way
merge (P6).

`survey`, `owed`, `catch-up`, `run`, `report`, `schedule`, `check` and
`stamp` are implemented: requirements R1 to R11, except that re-seeding
a vendored file (owed's `reseed`) is reported and not acted on, having
been needed zero times. Re-seeding vendored
files (owed's `reseed`) is not: it has been needed zero times so far,
and copier was verified by hand and set aside (see
`docs/requirements.md`). Running catch-up on a schedule is the
integrator's decision.

`test/run` runs the suite: the vendored conventions check, shellcheck,
and `test/survey.t`, `owed.t`, `catchup.t`, `profiles.t` and
`schedule.t`, which build real git repositories in a scratch directory
rather than stubbing git. Only systemctl is stubbed, and the unit
directory is proven to be inside the scratch directory first.
