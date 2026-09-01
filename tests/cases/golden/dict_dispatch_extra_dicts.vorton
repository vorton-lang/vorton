// B-121 gap 1: BinOp dispatch with extra_dicts — resolve_dispatch_dict must
// build a wrapped dict when TraitDispatch::Direct has non-empty extra_dicts.
// Previously the LLVM backend discarded extra_dicts (used `..` pattern) and
// dispatched through a base-only dict missing inner type-param bindings.

struct Pair<A, B> {
    first: A,
    second: B
}

impl<A: Eq, B: Eq> Eq for Pair<A, B> {
    fn eq(self, other: Pair<A, B>) -> Bool {
        self.first == other.first && self.second == other.second
    }
}

fn check_pair<T: Eq>(a: Pair<T, Int>, b: Pair<T, Int>) -> Bool {
    a == b
}

fn main() {
    let p1 = Pair { first: 1, second: 2 }
    let p2 = Pair { first: 1, second: 2 }
    let p3 = Pair { first: 1, second: 3 }
    print("eq=${check_pair(p1, p2)}")
    print("neq=${check_pair(p1, p3)}")
}
