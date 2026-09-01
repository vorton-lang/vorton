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

fn through_c<T: C>(value: T) -> Int { value.c_value() }
fn through_bc<T: B_C>(value: T) -> Int { value.bc_value() }

fn main() {
    print(through_c(A_B {}))
    print(through_bc(A {}))
}
