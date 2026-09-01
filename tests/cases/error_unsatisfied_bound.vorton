// Negative test: E0503 — unsatisfied trait bound
trait Printable {
    fn display(self) -> Str
}

fn show<T: Printable>(x: T) -> Str {
    x.display()
}

struct Blob { data: Int }

fn main() {
    show(Blob { data: 1 })
}
