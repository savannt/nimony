# Precompiled-concept DFA matcher — implementation brief

**Goal:** speed up nimony concept matching by *precompiling each concept into a
tree-automaton (NFA/DFA)*, adapting the existing engine in
`src/lengc/shoggoth/vmrewriter.nim`. This is the direction chosen to supersede
the LRU-cache approach of PR #1989 (nim-lang/nimony), which the author measured
at only ~30–50% and flagged for an "overall approach" review.

This worktree (`conceptdfa`, branched off PR #1989) keeps the PR's benchmark
scaffolding (`tconceptblowup`, `-d:nimonyProfileConcepts`) so we can compare.

---

## 1. Current concept-matching hot path (what we are replacing/augmenting)

Entry: `matchConceptBody(m, conceptSym, body, a)` in `src/nimony/sigmatch.nim`
(~line 668). To decide "does concrete type `a` satisfy concept `conceptSym`":

1. Recurse into parent concepts (`conceptParentSyms`).
2. For **each requirement routine** in the concept hierarchy
   (`conceptHierarchyRoutines(body)`), call `conceptRoutineAvailable` (~line 577).

`conceptRoutineAvailable` is the cost center:
- Binds every `Self` typevar in the requirement to `a` (save/restore of
  `m.inferred`).
- `basename = conceptRoutineBasename(routine)`.
- **Scans every candidate routine named `basename`** via
  `conceptRoutineCandidates(m.context, conceptSym, basename)` (in
  `sigconcepts.nim` ~line 121 — defining module syms + every imported iface +
  visible scope, deduped).
- For each candidate, `matchConceptRoutineSig(m, routine, cand)` (~line 534):
  structural param-type + return-type comparison via `tryLinearMatch` /
  `matchesConstraint`, with `Self` bound.

So cost ≈ Σ_requirements ( |candidates(basename)| × sig-compare ), repeated for
**every (concept, type) pair** the compiler checks. The PR memoizes three layers
of this (body result, per-requirement impl, candidate list).

## 2. The engine to adapt: `src/lengc/shoggoth/vmrewriter.nim`

A `lexim`-style **deterministic pushdown tree automaton** over NIF tokens
(header comment lines 1–31). Rules (LHS patterns over NIF trees) are merged per
root tag into a `Dfa` (subset construction, `buildScopeDFA` ~line 320) and run
by a VM over a `nifcore` cursor (`runScope` ~line 577). Salient machinery to
reuse:
- **Pattern reps** as a NIF tree with meta-tags: `@wild`, `@anyint`, `@anysym`,
  `@anylit`, `@pure`, `@same <reg>` (comment ~line 84).
- **Capture registers** (TDFA-style): transitions write registers; accept reads
  the winning rule's registers.
- **Guards**: `gkPure`/`gkSame` = runtime predicates on a transition
  (`isPureSubtree`, `subtreeEqual`).
- **`@same <reg>`** = "this subtree must structurally equal a previously
  captured one" — this is exactly the unification we need for `Self`.

## 3. Proposed mapping: concept requirement → automaton pattern

- A concept's **requirement signature** (a `proc/func/template` head with param
  types + return, `Self` appearing in them) becomes a **pattern tree**:
  - every occurrence of a `Self` typevar → `@same <regSelf>` (first occurrence
    captures the concrete type `T`; later occurrences must equal it).
  - other concept-level typevars → their own `@same`/`@wild` registers.
  - concrete type nodes → literal pattern tags (`Open(tag)` + kids).
- A **candidate routine's signature** (with the concrete `T` already the input)
  is the **input tree** fed to the automaton.
- **Acceptance** = "candidate satisfies requirement": automaton reaches an
  accept state AND kind-compatibility holds
  (`conceptRoutineKindsCompatible`, proc/func/template rules).
- **Precompile once per concept**, cache by concept `SymId`, invalidate on
  concept re-decl. The PR already added the lifecycle hook `onConceptDeclSem`
  (`conceptcache.nim`) — reuse that as the (re)compile trigger, and
  `onConceptImportsChanged` as the flush.

Merging *all* requirement patterns of a concept into one `Dfa` (as vmrewriter
merges sibling rules) is the stretch goal — it lets one automaton walk classify
a candidate against every same-shaped requirement at once. Start with
**one compiled pattern per requirement**; merge later.

## 4. PROFILE FIRST (do not skip)

Wire the `-d:nimonyProfileConcepts` counters (already declared in
`conceptcache.nim`) into the real call sites and measure a non-inheritance
stress case (see §6). Confirm the time is actually in candidate-scan +
sig-compare, **not** in `tryLoadSym`/inference save-restore. If it's the latter,
say so honestly — the DFA won't help there and we report that back before
building 500 lines. The user directed the DFA approach; pursue it, but measure.

## 5. Staged plan (first checkpoint is bounded & reviewable)

- **S0 — profile & baseline.** Instrument counters; build a non-inheritance
  stress benchmark; record where cycles go. Short written findings.
- **S1 — design note + prototype.** New module `src/nimony/conceptdfa.nim`:
  compile ONE non-inherited concept's requirement signatures into
  vmrewriter-style patterns; a `matches(concept, T, candidateSig)` entry point.
  Validate on 2–3 non-inheritance concepts vs. the existing matcher (identical
  accept/reject).
- **S2 — integrate as fast path.** Call the precompiled matcher from
  `conceptRoutineAvailable`/`matchConceptBody` with a **fallback** to the
  existing code; assert equal results in a debug build. Re-profile.
- **S3 — report.** What sped up, by how much, what didn't, next steps
  (inheritance, merged per-concept DFA, error-message paths).

Stop after S1 and report before doing S2 wiring.

## 6. HARD constraints (environment — read carefully)

- **`concept of` (inheritance) does NOT parse on this machine.** nifler links
  the *host* Nim compiler's parser, and this box's Nim devel (2.3.1) predates
  concept-inheritance syntax. So `tconceptblowup`, `tconceptcacheparent`,
  `tconceptinherit`, etc. **fail at parse time** ("identifier expected, but got
  'keyword of'") — this is an ENV limit, not a bug. **Verify only with
  non-inheritance concepts** (plain `X = concept` bodies). A working template:
  `/tmp/.../scratchpad/tc_plain.nim` (Addable concept) compiles+runs fine here.
- **NEVER run `hastur nimony` / `hastur all` / the full suite** — parallel
  compiler fan-out OOMs and crashes this WSL2 VM. Verify with
  `bin/nimony c <file>` or at most `bin/hastur test <dir> --jobs:1`. Never
  `nohup &`-detach a run.
- **Build AND edit in THIS worktree** (`/home/savant/nimony-conceptdfa`). Rebuild
  after edits with `nim c -r src/hastur build all` (works; ~1–2 min) — or just
  the tools you changed. Concept matching runs in **nimsem** (in-process during
  `nimony c`), so rebuild `bin/nimsem` + `bin/nimony` after touching sema.
- `--define:useMalloc` is appended to `src/config.nims` as a **do-not-commit**
  WSL2 workaround (nimsem segfaults without it here). Strip before any PR.
- **Git identity:** commits/PRs use `savant.eclipse@gmail.com` / name `savannt`.
  Do **not** push or open a PR without explicit approval.
