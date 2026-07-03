type
  Eqable = concept
    proc `==`(a, b: Self): bool
type Q = distinct int
proc `==`[X](a, b: X): bool = false      # fully generic candidate
proc `==`(a, b: Q): bool = int(a) == int(b)
proc useE[T: Eqable](a, b: T): bool = a == b
discard useE(Q(1), Q(2))
