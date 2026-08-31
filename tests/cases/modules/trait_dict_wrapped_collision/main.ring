trait C {
    fn c_value(self) -> Int
}

trait B_C {
    fn bc_value(self) -> Int
}

struct A_B {}
struct A {}

impl C for A_B {
    fn c_value(self) -> Int { 31 }
}

impl B_C for A {
    fn bc_value(self) -> Int { 42 }
}

trait PairRead {
    fn total(self) -> Int
}

struct Pair<X, Y> {
    left: X,
    right: Y
}

impl<X: C, Y: B_C> PairRead for Pair<X, Y> {
    fn total(self) -> Int {
        self.left.c_value() + self.right.bc_value()
    }
}

fn read_pair<T: PairRead>(value: T) -> Int { value.total() }

fn main() {
    print(read_pair(Pair { left: A_B {}, right: A {} }))
}
