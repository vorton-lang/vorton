// B-100 P1.1 parity: trait advanced dispatch — trait bound in fn-type param,
// higher-order trait passing (fn value with trait bound), multi-bound
// constraints (T: A + B).

// --- Trait bound in fn-type parameter ---

trait Showable {
    fn show(self) -> Str
}

impl Showable for Int {
    fn show(self) -> Str { self.to_str() }
}

impl Showable for Str {
    fn show(self) -> Str { self }
}

fn apply_show<T: Showable>(f: fn(T) -> Str, x: T) -> Str {
    f(x)
}

// --- Higher-order trait passing ---

struct Num { val: Int }

trait Displayable {
    fn display(self) -> Str
}

impl Displayable for Num {
    fn display(self) -> Str { "num(${self.val})" }
}

fn render<T: Displayable>(item: T) -> Str with {} {
    item.display()
}

fn apply_render(f: fn(Num) -> Str, item: Num) -> Str {
    f(item)
}

// --- Multi-bound constraints: T: A + B ---

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
    // Trait bound in fn-type parameter
    let r1 = apply_show(fn(x: Int) -> Str { x.show() }, 42)
    print("fn_param_int=${r1}")

    let r2 = apply_show(fn(x: Str) -> Str { x.show() }, "hello")
    print("fn_param_str=${r2}")

    // Higher-order trait passing
    let r3 = apply_render(render, Num { val: 99 })
    print("higher_order=${r3}")

    // Multi-bound constraints
    let w = Widget { name: "btn", size: 12 }
    print("multi_bound=${describe(w)}")
}
