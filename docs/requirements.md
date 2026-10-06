# muster requirements

Written 2026-09-30 from the tackup session, after an afternoon in
which every cross-repo operation went wrong in a different way. The
incidents are recorded at the end, and every requirement points at
one of them.

REQUIREMENTS, NOT PRESCRIPTIONS: each entry says what must be TRUE
and what breaks when it is not. The "possible shape" section is a
soft illustration, and is mostly a list of EXISTING tools to adopt
rather than reimplement, which is the most important conclusion
here.

## What it is

A stable interface over cross-repo coherence: one vocabulary for "what
state are these repos in" and "make this shared artifact agree across
them", dispatching to standard tools underneath and gap-filling what they
do not cover.

The shape is charon's, and the contract is charon's, restated:

> muster owns MECHANISM and safe defaults, and must run standalone with no
> tackup and no caller. tackup owns the FACTS ABOUT THIS FLEET: which
> repos, which artifacts, which paths. Neither restates the other.
>
> The test: delete tackup's config and muster still runs on its defaults;
> delete muster's defaults and tackup's declarations still fully determine
> behaviour.

AMENDED BY R12 (proposed 2026-10-05, agreed with the user): the one thing
muster will not default is WHAT IT MANAGES. With no config, or a config
with no `manage` line, it refuses and says which lines to add. Every
other default stands.

## What it is NOT

Held here so the boundary is visible rather than assumed, and because two
of these are things a tool like this drifts into by itself.

- NOT a release coordinator. A verification that takes longer than the
  interval between other sessions' commits cannot be made reliable by
  tooling; only a freeze does that, and a freeze is a human decision. The
  tractable ambition is "your verification is void, the tree moved".
- NOT a monorepo emulator. It does not build, publish, or version the
  repos it surveys.
- It knows NOTHING about agents, teams, sessions or work partitions.
  Callers have their own boundaries and they are the caller's.
- It does NOT enforce the work/personal boundary and must not try. That
  wall is the kernel (`work_dir` is `root:<group>` 2770 with a default
  ACL), so a personal-context muster physically cannot read a work repo.
  Honouring it by convention in a tool would be a soft rule standing where
  a hard boundary already is, which is the error this tree's notes name
  explicitly: enforcement, not a rule a model is asked to honor.

## Requirements

### R1. One place answers "what state is this set of repos in"

MUST BE TRUE: the question is answerable in one command, from one
implementation.

WHY: it was hand-rolled FOUR times in one afternoon, in four slightly
different forms, and two of those forms produced FALSE findings from their
own parsing: one split a target line on a tab because it used tab as a
field separator, the other dispatched a parse check on file suffix where
the real tool dispatches on shebang, and reported three healthy records as
broken. The repetition is the specification; the divergence between copies
is the reason it must be one implementation.

### R2. The THREE heads are distinguishable

MUST BE TRUE: for a repo installed from a moving pin, the report
separates
  origin's head, the dev checkout's head, and the DEPLOYED clone's head.

WHY: these were three different commits on this box today. `~/src/mux` was
at 9f8619c, `~/.cache/tackup/pkgs/mux` at f371cf4, and origin fourteen
commits further on. Reasoning proceeded from the dev checkout for an entire
conversation and was wrong about the tool's actual behaviour as a result.
This is also the axis no existing multi-repo tool models: they all compare
a working tree to its remote, and none knows about a clone installed from a
`head` pin that moves on every provision.

### R3. "Behind" and "I have not fetched" are different answers

MUST BE TRUE: a count computed from a possibly-stale remote-tracking ref is
never reported as though it were current.

WHY: `git status -sb` printed `## main...origin/main` on a checkout two
commits behind, because the ref it compares against was itself stale. The
reassuring answer and the true answer were different, and the tool said the
reassuring one. This tree already knows the rule and wrote it down: a
fallback must never stand in for an unanswerable question.

### R4. "Unreadable from here" is a THIRD state

MUST BE TRUE: a repo that cannot be read reports as unreadable, never as
absent and never as healthy.

WHY: the kernel wall means a personal context genuinely cannot stat inside
a work tree. Reporting that as "not a repo" or "missing" is a false claim
about the world, and it is the same shape as the `@{u}` fallback that made
a repo whose entire history was local read as fully pushed. Three states,
because there are three: fine, broken, and I could not look.

### R5. The DIAGNOSE path works on a broken box

MUST BE TRUE: the survey runs with no virtualenv, no network, and no
provisioning, in POSIX sh under dash.

WHY: muster is reached for exactly when something is wrong, and that is
when a Python dependency is least likely to be present. The reconcile path
may depend on heavier tools because mutating work can demand them; the
diagnostic half may not. Diagnose with nothing, repair with tools.

### R6. Nothing is written until the result is verified EVERYWHERE

MUST BE TRUE: a reconciled artifact is proven in every target repo before
it is committed to any of them.

WHY: the shared artifact here is a pre-commit checker, so a bad one does
not merely fail a test, it blocks every commit in fifteen repos. When this
was done by hand on 2026-09-30 the verification step was the whole job:
thirteen re-seeds, thirteen runs, 13/13 green, and only then thirteen
commits. Converging the files is not the goal; converging them without
breaking anyone is.

### R7. A conflict blocks nothing

MUST BE TRUE: an unresolvable difference is reported and leaves every repo
exactly as it was, green and usable.

WHY: the alternative is the state box A sat in all morning, where a
check reported a gap no local action could close and three provision runs
ended identically. A repo enforcing a slightly older style checker for a
day costs approximately nothing; a repo sitting red teaches people to
ignore the check, which this tree names as the worse outcome twice over.

This trade is correct BECAUSE the artifact is a style checker. It would be
a hole if borrowed for anything load-bearing, and someone will be tempted.

### R8. A dirty repo is skipped and reported, never stomped

MUST BE TRUE: uncommitted work in a target repo stops muster touching that
repo, and says so.

WHY: on box A two of the fifteen repos held another session's
in-flight edits while this ran. They were left alone deliberately, and the
operation still completed for the other thirteen. Someone mid-edit is not a
conflict to resolve; it is a repo to come back to.

### R9. Concurrent invocation is the NORMAL case

MUST BE TRUE: two muster runs that disagree produce a detectable
disagreement, not a silent winner.

WHY: today's collisions were two machines and two sessions. Any caller that
represents a team rather than an individual makes simultaneous runs the
default rather than the exception.

Determinism alone does not cover this, and that is the subtle part: two
runs observing the tree at different MOMENTS see different inputs, so they
compute different candidates and both are legitimately correct about what
they saw. The cheap protection is for a reconcile commit to RECORD ITS
INPUTS, the baseline version and the set of repo states it merged, so
"already applied" and "someone merged a different view" can be told apart
afterwards. That is asserted-versus-actual drift applied to the tool's own
output.

### R10. The machine form and the human form come from one code path

MUST BE TRUE: the parseable output and the table are the same computation.

WHY: single source of truth, and retrofitting a parseable form onto a
pretty printer is how the two start disagreeing. Any programmatic caller
wants a query ("is this repo safe to start work in") rather than a table,
and that query must not be a second implementation of the survey.

### R11. A verification that outlived its tree is reportable as void

MUST BE TRUE: it is answerable whether a recorded result still describes
the current tree.

WHY: a 35-minute gate went stale TWICE in one afternoon, because another
session landed work while it ran. Both times the result was green and both
times it described a tree that no longer existed. Nothing detected this;
it was noticed by hand. Detecting invalidation is tractable, and it is the
honest half of the release problem muster is otherwise staying out of.

### R12. What a box manages is DECLARED, never inferred (AGREED)

PROPOSED 2026-10-05, names and decisions agreed with the user; drydock
concurred the same day (T17), amended so each integrator emits a
`manage` line exactly when it writes a line of that kind. tackup's
concurrence is open. STEP 1 BUILT: `manage` enforced where declared,
`placed`/`place` profiles, check's two notes, and merge-back and capture
refusing a source outside a git work tree (found during T17: a payload
source took the write, exit 0, and the next install would erase it).

WHY: muster does two things, and a box may want either or both. Measured
on a scratch config holding only a `place` line: `check` listed an
implicit `default` profile over "all (0)" repos, and `muster run
default` there could not run, which the next `check` reported as a
FAULT. A box that only places could never clear its banner. Discovery
still defaulted to `~/src`, so a box that merely has clones there gets
surveyed whether anyone asked or not. The repo half's defaults leak onto
boxes that never declared it. Splitting muster in two was considered and
rejected: run, report, schedule, check, retro, the notifier, the state
dir and the box lock would all exist twice.

THE TWO KINDS, by the unit acted on:

- `repo`: a git repository as a whole (refs, remote, working tree):
  behind, diverged, dirty, unpushed, in use, its vendored copies and its
  deployed clone.
- `path`: a placed file at a path, by content and mode against a
  baseline; it needs no git (a source root outside git works). Named
  `path` rather than `file` because directories are already partly in
  scope (capture dirs, directory links, linked dest roots) and may be
  more so.

MUST BE TRUE:

- One kind per line, `manage repo` and `manage path`. Both on one line
  would read as "the repo path", which `repo <name> [<path>]` already
  means. A repeated line or an unknown kind is a config error.
- POSITION IS NOT LOAD-BEARING: every `manage` line is read before any
  other line is judged, so a generator may append them (measured: with
  `manage path` last, the lines above it were judged against it, and a
  repo line above it was refused by line number). First is the
  readable order, and recommended.
- NO `manage` LINE IS A CONFIG ERROR, and so is NO CONFIG: exit 2 for
  every verb except `help`, naming the lines to add. Nothing is inferred
  from the other lines present, which would be a second classification
  of the same fact.
- Without `manage repo`: no discovery and no implicit `default` profile;
  `survey`, `owed`, `catch-up`, `sync`, `push` and `stamp` exit 2 naming
  the missing line; `root`, `origin`, `repo`, `deployed`, `artifact`,
  `expect`, `hold`, `push-grace` and `reseed-grace` are config errors.
- Without `manage path`: `placed`, `place`, `merge-back`, `capture`,
  `diff`, `where`, `displaced` and `retire` exit 2 naming the missing
  line; `place`, `policy` and `capture` lines are config errors.
- Shared, serving whatever is declared: `run`, `report`, `schedule`,
  `check`, `retro`, `resolve` (each step only for a declared kind), and
  `notify`, `driver`, `keep`.
- A PROFILE'S VERB DECIDES WHAT IT COVERS. Profiles also take `placed`
  (observe: store placement faults, feed the banner) and `place` (act:
  place drift). A path profile covers every placed path, so a repo
  selector on one is a config error; two acting `place` profiles always
  overlap and are refused, as overlapping repo profiles are. No profile
  ever merges back or captures, as no profile ever pushes.
- `check` notes `manage path` with no profile observing placement, the
  same shape as the existing "no driver declared" note: nothing would
  ever feed the banner.

PHASING (the change breaks every config in use, and the frozen
placement format promised additive changes only, hence T17):

1. muster accepts `manage` and enforces it where present; a config
   WITHOUT it keeps today's behaviour (repo always, path if `place`
   lines exist), and `check` notes the missing lines.
2. The integrators (tackup, drydock) emit the lines on every box, and
   each box's `check` reads without the note.
3. muster makes absence fatal.

## Possible shape, wholly non-binding

### Adopt rather than write

The single most useful finding from scoping this: most of it exists, and
the decomposition three mature tools already use is evidence the
decomposition is right. These are LEADS TO VERIFY rather than facts; they
were recalled, not read.

    shared files vendored into N repos,        copier, or cruft for
    reconciled asynchronously                  cookiecutter templates

    pre-commit hooks without a vendored copy   pre-commit

    fan a change across repos, open PRs        multi-gitter, git-xargs

    propagate a version bump                   Renovate, if the artifact
                                               is a versioned dependency

    repo-level standards compliance            repolinter, allstar

    a multi-repo status table                  gita, myrepos, mu-repo

`copier` is the closest match to the reconciliation design and arrived at
the same answers independently: it keeps a committed local copy in each
project, records in `.copier-answers.yml` which template version it came
from (the baseline stamp), and `copier update` does a 3-way merge of old
template, new template and local modifications, flagging conflicts rather
than blocking. If that holds up on inspection, R6 through R9 are mostly a
wrapper around it rather than an implementation.

VERIFIED 2026-09-30, AND NOT ADOPTED. The description above held on every
point. It is set aside because a vendored copy here is never edited in
place: the canonical always wins, so the 3-way merge, copier's real value,
has nothing to merge. What is left (a baseline stamp, refusing a dirty
tree, per-repo paths) is a small amount of sh around `cp`, while a copier
wrapper would need guards of its own: a conflict exits 0 with markers
written into the file and the stamp bumped regardless, a differing file on
a non-terminal stdin hangs at an overwrite prompt, and once a template
carries any tag, untagged commits are ignored. Revisit if a vendored
artifact ever has to carry legitimate local edits.

`pre-commit` solves fan-out better than vendoring does: a repo REFERENCES a
hook repo at a pinned rev and `autoupdate` bumps the pin, so there is no
copy to drift. Two caveats for this fleet: it is Python, and it clones hook
repos into a cache on first use, so it wants the network once per repo.

### Build

The survey, because of R2 and R4: no existing tool models a clone
installed from a moving pin, and none has a reason to distinguish
"unreadable from this context" from "absent". Those two are also where
today's worst reasoning errors came from.

### Verbs from the problem, not from the backend

If `muster sync` is `copier update` renamed then it is an alias, not an
interface, and it breaks the day the backend changes. Verbs that survive a
backend swap: `survey`, `reconcile`, `owed`.

### Keep dispatch and gap-fill visibly apart

Otherwise nobody can tell a year later whether a given verb is muster's own
or a wrapper, and that ambiguity is how a facade becomes a fork.

## Measured, 2026-09-30, so it need not be re-derived

- Three heads differed for one package on one box: dev checkout 9f8619c,
  deployed clone f371cf4, origin fourteen commits ahead.
- `git status -sb` printed `## main...origin/main` on a checkout two
  commits behind, before any fetch.
- 15 repos carry the vendored conventions artifacts; the canonical pair
  lives in shared-notes. A hand fan-out is, per repo: fetch, pull, seed,
  run the seeded checker, stage an explicit path, commit, push.
- Re-seeding from a canonical that was itself 2 commits behind was avoided
  by checking, not by any tool.
- 13 of the 15 needed the re-seed (one already matched, one matched once
  it was pulled), and 13/13 passed the re-seeded checker before anything
  was committed anywhere.
- Dirty repos were left alone on both boxes: one here held another
  session's untracked file, and two on the other box held in-flight edits
  during a pull sweep. None was stomped and none blocked the rest.
- A 35-minute verification gate went stale twice in one afternoon.
- The same survey loop was hand-written four times, and two of those
  versions reported false findings caused by their own parsing.
