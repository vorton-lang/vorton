// Negative test: E0502 — missing method in trait implementation

trait Describable {
    fn name(self) -> Str
    fn describe(self) -> Str
}

struct Cat { n: Str }

impl Describable for Cat {
    fn name(self) -> Str { self.n }
    // Missing: describe
}

fn main() {
    let c = Cat { n: "Whiskers" }
}
