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

## Usage

    muster survey                 every repo under ~/src, as a table
    muster survey --porcelain     the same records, one line each
    muster survey --fetch         fetch first (the only network use)
    muster survey mux tackup      just these

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

### The porcelain

One line per repo, space-separated `key=value`, every key on every line,
`-` where a value does not apply, in this order:

    name state branch head upstream upstream_head ahead behind fetched
    modified untracked deployed path

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

`MUSTER_ROOT` overrides `root`. An unknown directive is an error, not a
skipped line.

## Status

`survey` is implemented. `reconcile` and `owed` are next, built in sh on
the survey's records: copier was verified by hand and set aside (see
`docs/requirements.md`).

`test/run` runs the suite: the vendored conventions check, shellcheck,
and `test/survey.t`, which builds real git repositories in a scratch
directory rather than stubbing git.
