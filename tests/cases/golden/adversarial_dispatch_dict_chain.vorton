// B-100 P1.3 adversarial: nested generic function calls with dict passing chain.
// fn f<T: Eq>(x: T) calls fn g<T: Eq>(x: T) — the dict must be forwarded.
// Also tests dict passing through 3+ levels and across different trait bounds.

trait Show {
    fn show(self) -> Str
}

struct Pt { x: Int, y: Int }

impl Eq for Pt {
    fn eq(self, other: Pt) -> Bool {
        self.x == other.x && self.y == other.y
    }
}

impl Show for Pt {
    fn show(self) -> Str { "(${self.x},${self.y})" }
}

// Level 3: innermost
fn inner_eq<T: Eq>(a: T, b: T) -> Bool {
    a == b
}

// Level 2: middle — forwards dict to inner_eq
fn mid_eq<T: Eq>(a: T, b: T) -> Bool {
    inner_eq(a, b)
}

// Level 1: outermost — forwards dict through mid_eq
fn outer_eq<T: Eq>(a: T, b: T) -> Str {
    if mid_eq(a, b) { "same" } else { "diff" }
}

// Two bounds on same T
fn eq_and_show<T: Eq + Show>(a: T, b: T) -> Str {
    if a == b {
        "eq:${a.show()}"
    } else {
        "ne:${a.show()}/${b.show()}"
    }
}

fn main() {
    // 3-level dict chain with Int
    print("int_chain=${outer_eq(10, 10)}")     // int_chain=same
    print("int_chain2=${outer_eq(10, 20)}")    // int_chain2=diff

    // 3-level dict chain with Str
    print("str_chain=${outer_eq("hi", "hi")}")    // str_chain=same
    print("str_chain2=${outer_eq("hi", "lo")}")   // str_chain2=diff

    // 3-level dict chain with struct
    let p1 = Pt { x: 1, y: 2 }
    let p2 = Pt { x: 1, y: 2 }
    let p3 = Pt { x: 3, y: 4 }
    print("pt_chain=${outer_eq(p1, p2)}")      // pt_chain=same
    print("pt_chain2=${outer_eq(p1, p3)}")     // pt_chain2=diff

    // Two bounds: Eq + Show
    print("dual=${eq_and_show(p1, p2)}")       // dual=eq:(1,2)
    print("dual2=${eq_and_show(p1, p3)}")      // dual2=ne:(1,2)/(3,4)
}
