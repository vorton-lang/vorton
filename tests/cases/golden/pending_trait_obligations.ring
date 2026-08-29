// B-170: bounded calls may wait until their declaration owner has collected
// surrounding annotation, return, branch, lambda, and associated constraints.

const STATIC_EMPTY: Set<Int> = set_from([])

struct Maker<T> {
    marker: List<T>,
}

impl<T: Hash + Eq> Maker {
    fn make(self) -> Set<T> {
        set_from(self.marker)
    }
}

trait EmptyMetric {
    fn empty_count(self) -> Int {
        let empty: Set<Int> = set_from([])
        empty.len()
    }
}

struct Metric {}
impl EmptyMetric for Metric {}

effect DefaultMetric {
    fn empty_count() -> Int {
        let empty: Set<Int> = set_from([])
        empty.len()
    }
}

trait Source {
    type Item
    fn item(self) -> Item
}

struct IntSource {}
impl Source for IntSource {
    type Item = Int
    fn item(self) -> Int { 1 }
}

fn unknown<T>() -> T {
    panic("B-170 unreachable type source")
}

fn hash_identity<T: Hash>(value: T) -> T { value }

fn hash_value<T: Hash>(value: T) -> Int with {} { value.hash() }

fn attach_source<T, S: Source<Item = T>>(source: S, _value: T) -> S {
    source
}

fn empty_same_map<T>() -> Map<T, T> { map_new() }

fn accept_set(value: Set<Int>) -> Int { value.len() }

fn return_set() -> Set<Int> { set_from([]) }

fn explicit_return_set() -> Set<Int> {
    return set_from([])
}

fn if_set(flag: Bool) -> Set<Int> {
    if flag { set_from([]) } else { set_from([2]) }
}

fn match_set(flag: Bool) -> Set<Int> {
    match flag {
        true => set_from([]),
        false => set_from([3]),
    }
}

fn invoke_factory(factory: fn() -> Set<Int>) -> Int {
    factory().len()
}

fn set_count(value: Set<Int>) -> Int {
    value.len()
}

fn hash_count(
    value: Int,
    callback: fn(Int) -> Int
) -> Int {
    callback(value)
}

fn main() {
    // The pending initializer is deliberately used by a later statement.  It
    // must remain monomorphic so both statements constrain the same ?T.
    let delayed = set_from([])
    let typed: Set<Int> = delayed
    print("let=${typed.len()}")

    let mut mutable: Set<Int> = set_from([])
    print("var=${mutable.len()}")

    print("outer=${accept_set(set_from([]))}")
    print("return=${return_set().len()}")
    print("explicit-return=${explicit_return_set().len()}")
    print("if=${if_set(true).len()}")
    print("match=${match_set(true).len()}")
    let lambda_count = invoke_factory(fn() { set_from([]) })
    print("lambda=${lambda_count}")
    let later_factory = fn() { set_from([]) }
    let later_lambda_count = invoke_factory(later_factory)
    print("later-lambda=${later_lambda_count}")

    let maker = Maker { marker: [] }
    let made: Set<Int> = maker.make()
    print("method=${made.len()}")
    print("const=${STATIC_EMPTY.len()}")
    let metric = Metric {}
    print("trait-default=${metric.empty_count()}")
    print("effect-default=${DefaultMetric.empty_count()}")
    print("explicit-param=${set_count(set_from([]))}")
    let explicit_hash = hash_count(9, hash_value)
    assert(explicit_hash == hash_value(9), "ground callable argument evidence")
    print("callable-argument=ok")

    if false {
        // map_get_panic registers before the result annotation constrains the
        // shared Map<T,T> key/value variable.
        let indexed: Int = empty_same_map()[unknown()]
        print(indexed)

        // Drain pass 1 sees hash_identity's T still pending.  Resolving the
        // later Source obligation applies Item = Int; pass 2 then resolves it.
        let pending = hash_identity(unknown())
        let _selected: IntSource = attach_source(unknown(), pending)
    }
}
