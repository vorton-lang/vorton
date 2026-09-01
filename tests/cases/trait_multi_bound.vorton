// M12: Multi-constraint trait <T: A + B> calling methods from both traits
trait Showable {
    fn show(self) -> Str
}

trait Measurable {
    fn measure(self) -> Int
}

struct Widget { name: Str, size: Int }

impl Showable for Widget {
    fn show(self) -> Str { self.name }
}

impl Measurable for Widget {
    fn measure(self) -> Int { self.size }
}

fn describe<T: Showable + Measurable>(x: T) -> Str {
    "${x.show()}: ${x.measure()}"
}

fn main() {
    let w = Widget { name: "btn", size: 12 }
    print(describe(w))
}
