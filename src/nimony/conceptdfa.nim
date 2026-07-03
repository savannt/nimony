#       Nimony
# (c) Copyright 2026 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## Precompiled structural pre-filter for concept requirement matching.
##
## Motivation (measured, see `CONCEPTDFA_BRIEF.md`): the concept-match hot path
## is `matchConceptRoutineSig` — a full interpretive structural comparison run
## once per (requirement, candidate) pair. On a 60-type stress benchmark it fires
## **9150** times while the candidate *list* is already cached. That count grows
## ~O(N^2) and is the dominant, un-cached cost.
##
## This module is the vmrewriter-style automaton analogue specialised to type
## trees: it walks a requirement signature as a **pattern** (with the concept's
## `Self` typevar as a `@same`-style capture bound to the concrete type `T`) and
## a candidate signature as the **input**, returning a fast *reject / maybe*
## verdict. The full `matchConceptRoutineSig` only needs to run on the "maybe"
## survivors.
##
## Correctness contract (validated by the `-d:conceptDfaCheck` shadow assert in
## `sigmatch.nim`): `mayMatch` must return `true` whenever the real matcher would
## accept — i.e. **no false negatives**. It only returns `false` on a *definite*
## structural impossibility. Concept requirement matching applies no implicit
## conversions (it uses `tryLinearMatch` under `ConstraintMatchFlags`), so a
## concrete-vs-concrete constructor/nominal mismatch is a sound reject; anything
## involving a typevar on either side is conservatively treated as "maybe".

include ".." / lib / nifprelude
include ".." / lib / compat2

import nimony_model, decls, programs, semdata, typeprops, conceptcache
import ".." / lib / symparser

proc isTypevarSym(s: SymId): bool =
  let res = tryLoadSym(s)
  res.status == LacksNothing and res.decl.symKind == TypevarY

proc resolveAlias(s: SymId): SymId =
  ## Follow plain `type Alias = Foo` chains to the underlying nominal sym so an
  ## alias and its target are not read as a mismatch. `distinct`/generic/object
  ## bodies (non-`Symbol` type impls) stop the walk, so distinct identity is
  ## preserved. Non-type syms (typevars) are returned unchanged.
  result = s
  var guard = 0
  while guard < 64:
    inc guard
    let res = tryLoadSym(result)
    if res.status != LacksNothing or res.decl.symKind != TypeY:
      break
    let impl = typeImpl(result)
    if impl.kind == Symbol:
      result = impl.symId
    else:
      break

proc sameNominal(a, b: SymId): bool =
  ## Alias- and instantiation-robust nominal-name equality (mirrors the
  ## base-name compare used by `conceptRoutineBasename` /
  ## `sameTreesButIgnoreSymIds`), after resolving plain type aliases.
  let ra = resolveAlias(a)
  let rb = resolveAlias(b)
  if ra == rb: return true
  var na = pool.syms[ra]
  extractBasename(na)
  var nb = pool.syms[rb]
  extractBasename(nb)
  na == nb

proc isSelf(s: SymId; selfSyms: openArray[SymId]): bool {.inline.} =
  # `selfSyms` is tiny (1-3 entries); a linear scan beats a per-call HashSet.
  for x in selfSyms:
    if x == s: return true
  false

proc shapeMatch(p, c: Cursor; selfType: Cursor; selfSyms: openArray[SymId]): bool =
  ## Structural pattern match of a requirement type subtree `p` against a
  ## candidate type subtree `c`, with `Self` bound to `selfType`. Returns
  ## `false` only on a definite, conversion-free mismatch.
  # `Self` hole: `@same selfType`. A concrete candidate must equal `selfType`;
  # a generic (typevar-bearing) candidate could still unify -> "maybe".
  if p.kind == Symbol and isSelf(p.symId, selfSyms):
    if not isCacheableConcreteType(c):    # candidate bears a typevar -> maybe
      return true
    # Decidable only for a bare nominal candidate vs a bare nominal `Self`
    # binding (the overwhelmingly common case); alias-resolve before compare.
    # For complex concrete subtrees, only a structural identity is a sure match;
    # otherwise stay conservative ("maybe") to preserve the no-false-negative
    # contract.
    if c.kind == Symbol and selfType.kind == Symbol:
      return sameNominal(c.symId, selfType.symId)
    return true
  # A non-`Self` typevar in the *requirement* acts as a wildcard.
  if p.kind == Symbol and isTypevarSym(p.symId):
    return true
  # A typevar anywhere in the *candidate* subtree could unify with a concrete
  # requirement -> do not reject.
  if not isCacheableConcreteType(c):
    return true
  case p.kind
  of ParLe:
    if c.kind != ParLe: return false
    if p.tagId != c.tagId: return false
    var pc = p
    var cc = c
    inc pc
    inc cc
    while pc.kind != ParRi:
      if cc.kind == ParRi:
        # candidate ran out of children first: structurally different arity of a
        # type constructor -> reject.
        return false
      if not shapeMatch(pc, cc, selfType, selfSyms): return false
      skip pc
      skip cc
    # requirement children exhausted; extra candidate children -> mismatch.
    return cc.kind == ParRi
  of Symbol, SymbolDef:
    if c.kind notin {Symbol, SymbolDef}: return false
    return sameNominal(p.symId, c.symId)
  of DotToken:
    return c.kind == DotToken
  of IntLit, UIntLit, FloatLit, StringLit, Ident, CharLit:
    return sameTrees(p, c)
  else:
    return true   # unknown token shape -> stay safe

proc kindsMayMatch(reqKind, candKind: SymKind): bool {.inline.} =
  ## Mirror of the first check in `matchConceptRoutineSig`
  ## (`conceptRoutineKindsCompatible`), kept dependency-free here. Conservative:
  ## when unsure, allow.
  if reqKind == candKind: return true
  if reqKind == ProcY and candKind in {FuncY, TemplateY}: return true
  if reqKind == FuncY and candKind == ProcY: return true   # needs noSideEffect; allow -> maybe
  false

proc mayMatch*(conceptR, implR: Cursor; selfType: Cursor;
               selfSyms: openArray[SymId]): bool =
  ## Fast structural pre-filter driven straight off the requirement cursor
  ## (`conceptR`). `false` => the full `matchConceptRoutineSig` is guaranteed to
  ## fail, so it can be skipped. `true` => "maybe", run the full matcher. Same
  ## cursor inputs as `matchConceptRoutineSig`. Used by the shadow validator;
  ## the gate uses the precompiled `mayMatchCompiled` below.
  if not kindsMayMatch(conceptR.symKind, implR.symKind):
    return false
  var cf = conceptR
  var ca = implR
  skipToParams cf
  skipToParams ca
  if cf.substructureKind != ParamsU or ca.substructureKind != ParamsU:
    return true   # unusual shape -> don't reject
  cf.into ParamsU:
    ca.into ParamsU:
      while cf.hasMore and ca.hasMore:
        let cTyp = takeLocal(cf, SkipFinalParRi).typ
        let aTyp = takeLocal(ca, SkipFinalParRi).typ
        if not shapeMatch(cTyp, aTyp, selfType, selfSyms):
          return false
      if cf.hasMore:
        # requirement demands more params than the candidate declares -> reject.
        return false
      # extra candidate params may carry defaults; the full matcher decides.
      while ca.hasMore:
        discard takeLocal(ca, SkipFinalParRi)
  # Return type is intentionally NOT a reject driver: the real matcher's
  # `conceptReturnTypesMatch` is deliberately lenient (bidirectional
  # `matchesConstraint` + structural fallbacks), so a strict return compare here
  # could reject a return it would accept. Params alone drive rejection.
  return true

# ---- precompiled path ------------------------------------------------------

proc compileReq*(routine: Cursor; selfSyms: openArray[SymId]): CompiledReq =
  ## Build the owned, reusable pattern for one requirement: its kind, `Self`
  ## syms, and an owned copy of each parameter type tree.
  result = CompiledReq(kind: routine.symKind)
  for s in selfSyms: result.selfSyms.add s
  var cf = routine
  skipToParams cf
  if cf.substructureKind != ParamsU:
    return result
  cf.into ParamsU:
    while cf.hasMore:
      let typ = takeLocal(cf, SkipFinalParRi).typ
      var buf = createTokenBuf(16)
      buf.addSubtree typ
      result.paramTypes.add ensureMove(buf)

proc mayMatchCompiled*(r: CompiledReq; implR: Cursor; selfType: Cursor): bool =
  ## Same verdict as `mayMatch`, but the requirement side is read from the
  ## precompiled pattern `r` instead of re-walking a cursor.
  if not kindsMayMatch(r.kind, implR.symKind):
    return false
  var ca = implR
  skipToParams ca
  if ca.substructureKind != ParamsU:
    return true
  var i = 0
  ca.into ParamsU:
    while i < r.paramTypes.len and ca.hasMore:
      let aTyp = takeLocal(ca, SkipFinalParRi).typ
      let pCur = cursorAt(r.paramTypes[i], 0)
      if not shapeMatch(pCur, aTyp, selfType, r.selfSyms):
        return false
      inc i
    if i < r.paramTypes.len:
      # requirement demands more params than the candidate declares -> reject.
      return false
    while ca.hasMore:
      discard takeLocal(ca, SkipFinalParRi)
  return true

proc getOrCompileReq*(c: ptr SemContext; reqSym: SymId; routine: Cursor;
                      selfSyms: openArray[SymId]): CompiledReq =
  ## Memoized precompiled pattern for a requirement, keyed by `reqSym` in the
  ## concept cache (flushed by `onConceptDeclSem`/`onConceptImportsChanged`).
  result = getCompiledReq(c, reqSym)
  if result == nil:
    result = compileReq(routine, selfSyms)
    putCompiledReq(c, reqSym, result)
