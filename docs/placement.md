# Placement: config as copies, with drift detection and merge-back

Written 2026-10-01, from a design conversation with the user and a
hand-check of the obvious off-the-shelf tool. REQUIREMENTS, NOT
PRESCRIPTIONS, in the same form as `requirements.md`: each says what must
be TRUE, why, and the evidence. "Possible shape" at the end is soft.

## Why this exists

An integrator (tackup) began by symlinking its config out of its repo into
`$HOME`: editing the live file edited the repo, and git carried it to the
other machine, a cheap substitute for a sync service. It also coupled every
deployed file to a source checkout, which caused a run of failures: a
checkout older than the code that was running, a tool writing its runtime
decisions into the integrator's working tree as drift, and every
self-location bug being "the deployed thing points back at its source".

So the integrator's install rule now says an installed artifact is PLACED
(a copy at its deployed location), never linked back into source. For
package CODE that is simple: copy it; nobody edits it live. For CONFIG it
is not, because config is the half people edit live, and the symlink never
lost an edit (the live file WAS the repo file). A naive copy would.

The integrator owns the POLICY (which trees, which files are editable).
muster owns the MECHANISM: drift detection, placing, and merge-back. The
contract is the same as for the rest of muster: delete the integrator's
declarations and muster still runs on its defaults; delete muster's
defaults and the declarations still fully determine behaviour.

## Adopt before build: chezmoi was checked by hand, and does not fit

chezmoi is a mature dotfile manager built for exactly this, so it was
checked first (v2.73.0, sandboxed, against a tree laid out like the
integrator's). It records what it last wrote, refuses to overwrite a live
edit without a terminal rather than hanging, and places source-only
changes safely. It was set aside for four measured reasons:

- It keeps a HASH of what it last wrote, not the content, so its merge
  hands the tool the new source where the base should be: a true
  three-way merge is impossible.
- Its merge-back (`re-add`) silently overwrote a source-side change when
  both sides had changed: exit 0, no warning, the edit gone.
- Its status reads the same for "edited live" and "edited on both sides",
  which is the difference between a merge-back and a conflict.
- It takes the executable bit only from a filename prefix: a +x source
  file was placed without it.

All four come from storing a hash where content was needed. That is the
one thing this design does differently.

## Requirements

### P1. A placed file is a copy, never a link into source

MUST BE TRUE: every destination muster manages is a regular file (or
directory) at its deployed location. No managed path resolves into a
source tree.

WHY: the coupling above. The integrator's check fails any deployed link
that resolves into a source tree; muster must never create one.

### P2. Every file has three versions, and the baseline is CONTENT

MUST BE TRUE: for each managed file muster knows the SOURCE (what the
integrator declares), the LIVE copy, and the BASELINE: exactly what muster
last placed, byte for byte, with its mode.

WHY: with two versions (source and live) a difference cannot be
attributed. The integrator's existing copy mechanism has two, so its
"push" overwrites live edits and its "capture" overwrites repo changes.
With a baseline that is only a hash, a difference can be attributed but
not merged (chezmoi, above).

THE STORE (the user's design): a sparse mirror of the filesystem under a
well-known muster directory, e.g. `~/.local/state/muster/root/<absolute
destination path>`. A file's PRESENCE there means it is tracked, its
CONTENT is the baseline, and its MODE is the baseline mode. There is no
second database to drift from it.

### P3. Each file gets one verdict, and every verdict says its remedy

MUST BE TRUE: comparing the three versions yields exactly one of:

    in sync      source = baseline = live
    place        source changed, live = baseline: overwrite live, safe
    merge back   live changed, source = baseline: fold live into source
                 (user-editable only; P10)
    displace     live changed on a REPO-OWNED file (whether or not the
                 source did): move the live edit aside, then place (P4)
    conflict     both changed, differently, on a user-editable file: a
                 human decides
    converged    both changed, identically: record the baseline only
    new          in source, never placed: place it
    orphan       gone from source, still placed (see P8)
    unmanaged    live exists, no baseline: never touched (see P10)
    unreadable   could not look (R4: never reported as absent)

and maps onto muster's exit contract: what a place or merge-back repairs
is DRIFT (exit 1); a conflict, or anything no command repairs, is a FAULT
(exit 3).

WHY: the four cases chezmoi could not tell apart are the four that need
different remedies, and a check that blurs a fault into drift is the
"apply did not fix" loop the integrator has paid for more than once.

### P4. No edit is ever lost, on either side, under any policy

MUST BE TRUE: no write by muster ever destroys content that exists
nowhere else. The guarantee holds for every policy; what the policy
decides (P10) is only whether muster may MOVE an edit out of the way:

- USER-EDITABLE: placing never overwrites a live file that differs from
  its baseline. That is a conflict, and a conflict touches nothing.
- REPO-OWNED: placing may overwrite a live edit, but only by DISPLACING
  it first: the live content and mode are copied to the displaced store
  (below), the copy is verified byte for byte, and only then is the live
  file replaced. If the copy cannot be made or verified, nothing is
  overwritten, and that is a fault. Naming an overwritten edit is not
  enough: named but gone is still lost.
- APP-OWNED: placing never overwrites (it only seeds what is absent), so
  nothing is ever displaced.
- MERGING BACK never overwrites a source file that differs from its
  baseline, for any policy: that is a conflict.

THE DISPLACED STORE mirrors the baseline's layout:
`<state>/displaced/<UTC time>/<absolute destination path>`, content and
mode as they were. It is never pruned automatically. Every displacement
is reported where it happens, and until someone reviews and clears it,
`check` reports each entry as a FAULT (exit 3): clearing it is a person's
decision, and no apply can make it, which is exactly what muster's
contract says a fault is. A live edit to a repo-owned file is something a
person did, and a person should see it.

WHY: this is the guarantee the symlink gave for free, and the one the
migration must not regress. chezmoi failed it on the source side. An
earlier draft of these requirements contradicted itself here (P4 said
never overwrite, P10 said repo-owned overwrites "and says so"); review
caught it, and "says so" now means PRESERVED AND RECOVERABLE, not merely
named.

AND THE BASELINE MOVES ONLY AFTER A VERIFIED WRITE: a place updates the
baseline only once the live file is proven to hold what was intended; a
merge-back only once the source is. Every write is atomic (temp file and
rename, in the same directory), so a reader sees old or new, never half.
A baseline that is wrong is worse than none: it makes the next verdict
lie.

### P5. Merge-back writes into the source WORKING TREE, and only there

MUST BE TRUE: a merge-back writes the live content into the integrator's
working tree and stops. It never commits, never pushes, and never writes
into a source file that git reports as modified (someone is mid-edit:
R8). It records which source commit the baseline was placed from, so
"this live file is newer than commit X" is a checkable fact.

WHY: the user's starting position: merging back into the repo makes the
repo current, at a point in time that can be verified. Leaving it
uncommitted keeps it reviewable (`git diff`) without a new review step.

### P6. A conflict can be resolved with a real three-way merge

MUST BE TRUE: because the baseline is content, muster can produce a
three-way merge (live, source, base) for a conflicted file, written
somewhere reviewable, never in place on either side without an explicit
step.

WHY: the reason to store content (P2). A clean merge still deserves a
look; a conflicted one needs a human.

### P7. Mode is part of the file

MUST BE TRUE: the baseline carries the file's mode, the comparison
includes it, and placing reproduces it. A mode-only change is drift like
any other.

WHY: the user: "modes in the tree will solve a lot of churn previously
wrangled with". And chezmoi dropped an executable bit.

### P8. Deletion intent comes from the source, and only from the source

MUST BE TRUE:

- Removed from the source, live = baseline: remove the live file and its
  baseline. The source change (a commit) IS the recorded intent.
- Removed from the source, live edited: on a user-editable file a
  conflict, touching nothing; on a repo-owned file, displace the edit
  (P4), then remove.
- Removed live, still in the source: NOT intent. It is placed again on
  the next run, and that is reported.
- A source tree that is missing, empty or unreadable is a FAULT, and
  nothing is deleted: never "everything was removed".

WHY: the user: "files will always come back without some kind of
intent". Making the source the one channel means no tombstones and no
second list of deletions to drift. The mass-deletion guard is charon's
lesson (unison's `confirmbigdel`): a missing tree propagates as the
deletion of everything.

### P9. The map is a few root pairs, declared by the integrator

MUST BE TRUE: the integrator declares SOURCE ROOT to DESTINATION ROOT
pairs with a policy each, not a per-file list; muster resolves any path
in both directions by longest prefix, and can say, for any destination,
which source file it comes from.

WHY: the integrator's tree already mirrors its destinations (its config
tree maps file for file onto `~/.config`), so a per-file map would be a
second copy of the tree, free to drift. A resolver answers the user's
"take a full path and resolve it to where it lives".

LAYERS (several sources for one destination, e.g. a per-host overlay)
are to be designed into the resolver, with merge-back going to whichever
layer supplied the file, but not built until a layer is in use.

### P10. Policy is per root, and there are three

MUST BE TRUE:

    user-editable  full three-way handling, merge-back offered (P3-P6)
    repo-owned     place overwrites a live edit only by DISPLACING it
                   first (P4): preserved, verified, reported, recoverable
    app-owned      the application rewrites the file itself: place only
                   when absent (seed), and capture back only explicitly

Anything in a destination with no baseline is UNMANAGED and never
touched: muster owns only what it placed.

WHY: config ownership already splits this way in the integrator (its
app-owned files are copied and seeded, not linked, because the apps
replace them atomically and break symlinks).

### P11. Root-owned destinations are reported, never written

MUST BE TRUE: a destination muster cannot write as the user (root-owned
paths such as `/etc`) can still be compared and its drift reported, as a
fault whose remedy names what can write it.

WHY: user-level muster must not need privilege, and these change rarely.
The user: reporting drift "might be good enough".

### P12. Migration from links is part of the job

MUST BE TRUE: placing a destination that is currently a symlink into its
own source replaces the link with a copy and records the baseline, losing
nothing, because the live file and the source were one file. A symlink
pointing anywhere else is a fault. A whole-directory link is replaced by
a real directory of placed files, and anything only visible through the
old link (untracked files inside the linked source directory) is reported
before it disappears from view.

WHY: the integrator has on the order of a hundred such links plus a few
whole-directory ones, and the migration is the risky moment.

### P13. One infrastructure: muster's, and charon's approach

MUST BE TRUE: placement uses the machinery muster already has (profiles
and their timers, the run store, report, the notifier, `check`'s drift
and fault exits, porcelain and table from one computation, unreadable as
its own state) rather than a second copy of any of it. Where charon has
solved the same kind of problem (atomic writes, a mass-deletion guard,
never treating its own temporary files as content, a go / skip / fault
gate), the same approach is used.

WHY: the user: charon and muster "should share as much as possible in
terms of approach and even infra/tooling if it makes sense, but they are
quite different". They are: charon keeps a cache of a remote tree in step,
both directions automatically; placement maps several declared roots onto
scattered destinations, per-file policy, with merge-back an explicit step
into a git working tree.

## What it is NOT

- NOT a sync service. Nothing propagates both ways automatically; the
  automatic both-way behaviour is the symlink behaviour being retired.
- NOT a template engine. Rendering (a per-host overlay, say) is the
  integrator's; muster compares and places what it is given.
- NOT for package code. Payloads are placed by the integrator's install,
  with no merge-back, since shipped code is never edited live.
- NOT privileged. Root-owned destinations are reported only (P11).

## Possible shape, non-binding

- A config line per root pair, e.g.
  `place <source-root> <destination-root> <user-editable|repo-owned|app-owned>`.
- Verbs from the problem: one that reports per-file verdicts (the
  placement analogue of `owed`), one that places, one that merges back,
  and `where <path>` for the resolver. Names to be settled.
- `check` gains the placement drift and faults; a profile can run the
  report on a timer and the notifier raises a flag on drift, as now.
- The mirror root's location follows `MUSTER_STATE_DIR`.

## Open questions

- The exact boundary of the first increment: `~/.config` leaf files only,
  before whole-directory links and `~/bin`.
- Whether a clean three-way merge may be applied with one explicit
  command, or always written aside for review.
- How app-owned "capture" relates to merge-back: the same step with a
  different default, or its own verb.
