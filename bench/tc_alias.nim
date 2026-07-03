type Meters = int          # plain alias
type
  Measurable = concept
    proc dist(a: Self, unit: Meters): Self
type P = distinct int
proc dist(a: P, unit: int): P = a       # candidate declares `int`, not `Meters`
proc useM[T: Measurable](x: T): T = dist(x, 5)
discard useM(P(3))
