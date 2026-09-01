// expect: error
// expect: E0501
// Forward reference in supertrait creates unknown trait error
// (trait B is not yet defined when trait A references it)
trait A: B { fn a(self) -> Int }
trait B: A { fn b(self) -> Int }
fn main() {}
