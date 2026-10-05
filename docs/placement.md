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
    source link  the SOURCE is a symlink: never placed, a fault naming
                 it (added 2026-10-02, T11: it was dropped in silence,
                 which would have deleted commands from PATH)
    unreadable   could not look (R4: never reported as absent)

and maps onto muster's exit contract: what a place repairs is DRIFT
(exit 1), since an integrator's apply runs place; a conflict, or anything
that needs a person, is a FAULT (exit 3). A PENDING MERGE-BACK IS A
FAULT: merge-back is an explicit verb, never run by an apply (decided
with the integrator, 2026-10-01: an apply that folds live edits into a
shared working tree is the very thing placement retires, and these trees
are routinely worked by other sessions), so as drift it would schedule an
apply that could never clear it. Until it is merged back, the edit is not
in the source and no other machine will get it.

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

A STEADY STREAM OF DISPLACEMENTS MEANS A FILE IS MISCLASSIFIED, never
that the tool is noisy: a file an application rewrites is app-owned
(never overwritten), and one a person edits on purpose is user-editable
(merged back), so a correctly classified repo-owned file is not edited
live and its store stays empty. The remedy for recurring faults is a
per-file override (P10), not a quieter overwrite. This is deliberately
more conservative than "repo-owned is simply overwritten", which is how
the policy was first described: blind overwrite would hide exactly the
signal that a classification is wrong.

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

MUST BE TRUE: merge-back is an EXPLICIT step a person runs, never part
of an automatic apply (the integrator's decision, for the reasons in P3:
its counterpart, the existing copy mechanism's "capture", is likewise
kept out of the sweep). A merge-back writes the live content into the
integrator's
working tree and stops. It never commits, never pushes, and never writes
into a source file that git reports as modified (someone is mid-edit:
R8).

"Which source commit was this baseline placed from" is a checkable fact,
DERIVED FROM GIT, never stored: the baseline's content, hashed as a git
blob, is looked up in that source file's history,

    git log --find-object=<blob> -- <source path>

and the MOST RECENT commit that introduced that blob is the answer: the
same content can be introduced, changed away and later restored, and the
lookup lists every such commit, including the ones that removed it. If
no commit holds it, the file was placed from uncommitted source, and
that is said rather than guessed. Storing the commit beside the baseline
would be the second database P2 forbids, free to disagree with the
history it describes.

WHY: the user's starting position: merging back into the repo makes the
repo current, at a point in time that can be verified. Leaving it
uncommitted keeps it reviewable (`git diff`) without a new review step.
Deriving the commit is the integrator's review point, settled
2026-10-01: the repo is the source of truth, so "which commit" is a
`git log` question.

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
- Removed from BOTH sides (a captured file someone decides against):
  only the baseline remains, read as `orphan`, drift, until the next
  `place` clears it. So retiring such a file is: remove it from the
  source, remove it live, then `place`; without the last step check stays
  at exit 1 with nothing visible left to fix. Removing it live alone
  brings it back, byte-identical: retiring is a commit to the source.
- A source tree that is missing, empty or unreadable is a FAULT, and
  nothing is deleted: never "everything was removed".

WHY: the user: "files will always come back without some kind of
intent". Making the source the one channel means no tombstones and no
second list of deletions to drift. The mass-deletion guard is charon's
lesson (unison's `confirmbigdel`): a missing tree propagates as the
deletion of everything.

### P9. The map is a few root pairs, declared by the integrator

MUST BE TRUE: the integrator declares SOURCE ROOT to DESTINATION ROOT
pairs, each with a DEFAULT policy (per-file overrides: P10), not a
per-file list; muster resolves any path
in both directions by longest prefix, and can say, for any destination,
which source file it comes from.

WHY: the integrator's tree already mirrors its destinations (its config
tree maps file for file onto `~/.config`), so a per-file map would be a
second copy of the tree, free to drift. A resolver answers the user's
"take a full path and resolve it to where it lives".

THE INVENTORY IS THE INTEGRATOR'S, and comes BEFORE declaration: it
declares and tracks only config that earns it, never files that merely
restate an application's defaults (one package found three of its four
directives were restated defaults). muster places exactly what it is
given and does not judge what is worth tracking.

LAYERS (several sources for one destination) were left unbuilt until a
layer was in use. One now is: see P14, PROPOSED 2026-10-05.

### P10. Three policies: a per-root default, with a per-file override

MUST BE TRUE: each declared root carries a DEFAULT policy, and any file
within it may OVERRIDE that default, declared by the integrator per file
(by path). A file's effective policy is its override if it has one, else
its root's default. The three policies:

    user-editable  ("tracked": live edits flow back) full three-way
                   handling, merge-back offered (P3-P6)
    repo-owned     ("untracked": live edits do not flow back) place
                   overwrites a live edit only by DISPLACING it first
                   (P4): preserved, verified, reported, recoverable
    app-owned      the application rewrites the file itself: place only
                   when absent (seed), and capture back only explicitly

A CAPTURE DIRECTORY (`capture <dest-dir>`, added 2026-10-01, increment 2)
is where an application CREATES files, not just rewrites them: hwdp
captures display layouts into kanshi's profiles directory. Its files are
app-owned, but unlike a plain app-owned file the app's work is TRACKED:
a file the app created (no source, no baseline) or changed since it was
placed is verdict `capture`, folded into the source working tree by the
explicit `muster capture` (never committing, never over a source file git
reports modified, like merge-back), and a check FAULT until then, for
merge-back's reason: no apply runs it, and until it runs the work is in
no repo and no other machine gets it. A source change with the live file
untouched is placed (the other machine captured and committed it); both
changed is a conflict. Deletion intent still comes only from the source
(P8): an app's deletion is restored. A per-file `policy` line inside a
capture directory still wins.

Anything in a destination with no baseline is UNMANAGED and never
touched: muster owns only what it placed.

WHY PER FILE: a root is often MIXED. The integrator's config tree holds
user-editable and repo-owned files side by side, and splitting the tree
by policy would reshape the repo to suit the tool. A per-root default
keeps the common case to one line; the override covers the exceptions
without a second tree. Settled in the integrator's review, 2026-10-01.

APP-OWNED IS THE INTEGRATOR'S EXISTING COPY-AND-SEED MECHANISM folded in:
its seed and explicit capture become this policy, while the integrator
keeps the declarations and any case that is not a placed file (a
merge into a file the user also edits, such as a bookmarks list keyed by
label, stays the integrator's).

WHY THREE: config ownership already splits this way in the integrator (its
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
pointing anywhere else is a fault. A whole-directory link (the
destination ROOT itself included: T12, a root linked into its own source
read every file in-sync, the same inode on both sides) is replaced by
a real directory of placed files, and anything only visible through the
old link (untracked files inside the linked source directory) is reported
before it disappears from view. A whole-directory link that shows a
symlink (tracked or not) is NOT migrated: only regular files are copied,
so the symlink would vanish with the link. The migration is refused,
each such entry named, and the link left exactly as it was.

WHY: the integrator has on the order of a hundred such links plus a few
whole-directory ones, and the migration is the risky moment.

WHEN A SOURCE MOVES, SWEEP THE OLD LINKS FIRST. "Its own source" is read
from where a link RESOLVES, so a link left pointing at the source's OLD
path is `foreign`, reported every run and never touched, and it dangles
until the integrator removes it. Measured live (2026-10-02): a runtime
contract went unreadable through exactly such a link. Correct by the
rule above, since muster cannot know a vacated path was ever a source;
so moving a place source is a two-step job for the integrator: remove
the old publishes, then `place`.

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

### P14. Layers: one destination root, several sources (AGREED, BUILT)

BUILT 2026-10-05: verdicts `layered`, `unlayered` and `unhomed` (an
application's file whose capture directory is in no single layer), the
layer record beside the mirror at `<state>/layer/<path>`, the `check`
note for unrecorded baselines, `muster retire <layer-source>` and
`muster retire unrecorded`, and `where` naming the layer. A destination
root no longer declared at all is covered too: its baselines read
`unlayered`, where before they were silently abandoned.

PROPOSED 2026-10-05; CONCURRED by the integrator the same day (T16 in its
requests file) with one amendment and an answer to the open question,
both adopted below; agreed with the user.

WHY: a root is FLAVOR-BLIND. The integrator declares one root over all
of its config, and every box that runs muster gets every file in it.
Measured: a server with no compositor had 161 files placed, 78 of the
102 under that root desktop-only. Its modules respect flavor; its
placement could not.

THE INTEGRATOR KEYS LAYERS ON ITS CATEGORIES (its amendment): one source
directory per category, one `place` line per category the box takes,
derived from the same manifest that decides which modules a flavor gets.
A second classification of the same fact would drift from the first, so
there is none. To muster a layer is simply a `place` line, and its
identity is its SOURCE ROOT PATH.

MUST BE TRUE:

- Several `place` lines may share a destination root. The same source
  root twice is refused, as a duplicate. Each line keeps its own default
  policy; a `policy` line still applies by destination path.
- A file is OWNED by the one layer whose source supplies it. Supplied by
  two at once is a FAULT (`layered`) naming both, and nothing is placed
  for it: no precedence until a use needs one. (The integrator's known
  future case, per-role and per-host overrides, wants MOST-SPECIFIC-WINS
  stated as explicit specificity, never declaration order, which a
  generator would hide.)
- Merge-back and capture write to the layer that supplies the file. A
  capture directory must exist in exactly one layer's source, or it is
  a fault.
- A file moved from one layer to another is a MOVE: the new layer
  supplies it and nothing is removed.
- Ownership by the most specific root (P9) still comes first: layers are
  the roots of EQUAL destination.
- `where <path>` names the layer.

REMOVAL IS DECIDED BY CAUSE, NOT BY COUNT (the integrator's answer, which
replaced a proposed count threshold: a real 22-file retirement would have
tripped it, and a 3-file accident would have passed under it):

- THE BASELINE RECORDS THE LAYER that supplied each file, since the
  question is asked exactly when that layer is gone.
- Source file gone, its layer STILL DECLARED: the integrator deleted it.
  `orphan`, removed as P8 says.
- Its layer NO LONGER DECLARED, and no other layer supplies the file: the
  BOX changed flavor, which is not a decision about files. `unlayered`, a
  FAULT, removing NOTHING, naming the layer.
- `muster retire <layer-source>` confirms ONE layer, once: its files are
  removed under the usual guarantees (P4: a repo-owned live edit is
  displaced first, an edited user-editable file is left as a conflict,
  an app-owned file is only forgotten). Nothing outside that layer is
  touched, so no unrelated orphan rides along.

ORDERING, the one trap: baselines placed before this existed carry no
layer. So every `place` records (and backfills) the layer of each file a
layer supplies, and `check` notes any baseline still without one. A
baseline with no recorded layer that no layer supplies is `unlayered`
(layer unrecorded), never an orphan: unknown cause, so nothing removed.
The integrator changes its layers only after one `place` has run under
the old config on each box, which the note lets it verify.

## The config format: FROZEN for the first increment (2026-10-01)

What an integrator writes, and what it may rely on. Any change is
ADDITIVE ONLY and agreed first through the integrator's requests file;
nothing below changes meaning under a config that already parses.

    place <source-root> <dest-root> <policy>
    policy <dest-path> <policy>

    <policy>   user-editable | repo-owned | app-owned

- Paths are absolute or `~/`-relative, contain NO whitespace, and a
  trailing `/` is ignored.
- `<source-root>` is a directory. Inside a git work tree its source files
  are the tracked ones plus new, unignored ones, read from the working
  tree; gitignored files are never source. Outside git, every file.
- `<dest-root>` is a directory, created as needed.
- No two `place` lines may share a `<source-root>`. AMENDED 2026-10-05
  (P14, additive: no config that parsed before changes meaning): lines
  sharing a `<dest-root>` are LAYERS, where before they were refused.
  Nesting is allowed: the MOST SPECIFIC root owns its subtree, and a
  source file of an outer root that lands inside an inner root is
  `shadowed` (a fault, never acted on).
- ADDED 2026-10-01 (increment 2, additive, agreed with the user):
  `capture <dest-dir>`, one directory, under some declared `<dest-root>`,
  once; see P10.
- `<dest-path>` names exactly one destination file, under some declared
  `<dest-root>`. A `policy` line for a path under no root, or a second
  `policy` line for the same path, is a config error: it could never
  take effect, or could take one of two.
- Any violation above is exit 2 for every verb (the config is invalid),
  never a silently skipped line.

The state the engine keeps lives under `$MUSTER_STATE_DIR` (default
`~/.local/state/muster`): the baseline mirror at `root/`, kept edits at
`displaced/`. The exits the integrator maps:

    placed            0 all in sync   1 anything not   2 cannot run
    place, merge-back, capture
                      0 in sync after 1 something left 2 a write failed
    check             0 / 1 drift / 3 fault / 2 invalid config

## Possible shape, non-binding

- (The config lines are no longer a possible shape: see the frozen
  format above.)
- Verbs from the problem: one that reports per-file verdicts (the
  placement analogue of `owed`), one that places, one that merges back,
  and `where <path>` for the resolver. Names to be settled.
- `check` gains the placement drift and faults; a profile can run the
  report on a timer and the notifier raises a flag on drift, as now.
- The mirror root's location follows `MUSTER_STATE_DIR`.

## Open questions

- SETTLED 2026-10-01: the first increment is `~/.config` leaf files;
  whole-directory links and `~/bin` follow.
- Whether a clean three-way merge may be applied with one explicit
  command, or always written aside for review.
- How app-owned "capture" relates to merge-back: the same step with a
  different default, or its own verb. (App-owned is settled as the
  integrator's copy-and-seed mechanism folded in; P10.)
