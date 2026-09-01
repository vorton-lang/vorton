// Audit #258 negative: even with a pure handled body, all operation arms for
// one generic effect share the type arguments of one evidence value.

effect Pair<T> {
    fn first() -> T
    fn second() -> T
}

fn incoherent_pure_handler() -> Int {
    handle {
        0
    } with {
        Pair.first() => 1,
        Pair.second() => "text",
    }
}

fn main() {}
