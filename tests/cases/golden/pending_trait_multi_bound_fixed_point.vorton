trait Source {
    type Item
    fn item(self) -> Item
}

struct LinkOne {}
struct LinkTwo {}
struct LinkThree {}
struct LinkFour {}
struct LinkFinal {}

impl Source for LinkOne {
    type Item = Int
    fn item(self) -> Int { 1 }
}

impl Source for LinkTwo {
    type Item = LinkOne
    fn item(self) -> LinkOne { LinkOne {} }
}

impl Source for LinkThree {
    type Item = LinkTwo
    fn item(self) -> LinkTwo { LinkTwo {} }
}

impl Source for LinkFour {
    type Item = LinkThree
    fn item(self) -> LinkThree { LinkThree {} }
}

impl Source for LinkFinal {
    type Item = LinkFour
    fn item(self) -> LinkFour { LinkFour {} }
}

// One call obligation, with bounds deliberately ordered opposite to the
// associated-type source.  Each pass can unlock only the preceding bound:
// E -> D -> C -> B -> A.  This requires more than three observations.
fn reverse_chain<
    A: Hash,
    B: Source<Item = A>,
    C: Source<Item = B>,
    D: Source<Item = C>,
    E: Source<Item = D>
>(
    _a: List<A>, _b: List<B>, _c: List<C>, _d: List<D>, value: E
) -> E {
    value
}

fn main() {
    let _resolved = reverse_chain([], [], [], [], LinkFinal {})
    print("multi-bound-fixed-point=ok")
}
