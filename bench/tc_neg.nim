type
  Numeric = concept
    proc `+`(a, b: Self): Self
    proc `*`(a, b: Self): Self
type D = distinct int
proc `+`(a, b: D): D {.borrow.}
proc use[X: Numeric](a, b: X): X = a + b
discard use(D(3), D(2))
