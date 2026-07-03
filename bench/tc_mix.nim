type
  Scalable = concept
    proc scale(x: Self, factor: int): Self
    proc `==`(a, b: Self): bool
type
  V = distinct int
  W = distinct int
proc scale(x: V, factor: int): V = V(int(x) * factor)
proc `==`(a, b: V): bool = int(a) == int(b)
# decoys with same basename but wrong concrete param/other Self -> must be rejected, never a false-neg
proc scale(x: W, factor: string): W = W(0)
proc scale(x: W, factor: int): W = W(int(x) * factor)
proc `==`(a, b: W): bool = int(a) == int(b)
proc useSc[T: Scalable](x: T): T = scale(x, 2)
discard useSc(V(3))
