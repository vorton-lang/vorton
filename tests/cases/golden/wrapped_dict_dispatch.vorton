// B-087 gap 2: a WRAPPED trait dict — a generic Eq bound instantiated to a
// PARAMETERIZED type (e.g. Result<Int, Str>) whose Eq impl itself needs the inner
// type-param dicts (Int's Eq, Str's Eq) bound in. The checker emits DictRef::Wrapped
// { dict: Result_Eq, trait_name: "Eq", inner_dicts: [Int_Eq, Str_Eq] }. The LLVM
// resolve_dict_ref returned null for Wrapped → method dispatch through null → crash.
// Fix: construct a real wrapper dict that forwards each method to the base dict with
// the inner dicts appended.

enum Pair<A, B> { Both(A, B) }

impl<A: Eq, B: Eq> Eq for Pair<A, B> {
    fn eq(self, other: Pair<A, B>) -> Bool {
        match self {
            Pair::Both(a1, b1) => match other {
                Pair::Both(a2, b2) => a1 == a2 && b1 == b2,
            },
        }
    }
}

// generic Eq over T — T will be Pair<Int, Str>, a parameterized type → Wrapped dict
fn eq_check<T: Eq>(a: T, b: T) -> Bool { a == b }

fn main() {
    let p1 = Pair::Both(1, "x")
    let p2 = Pair::Both(1, "x")
    let p3 = Pair::Both(2, "y")
    print(eq_check(p1, p2))   // true  (wrapped Pair Eq with inner Int/Str Eq)
    print(eq_check(p1, p3))   // false
}
