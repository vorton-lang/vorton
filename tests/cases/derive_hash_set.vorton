// B-107: structural Hash shares auto-Eq decomposition and is stable across
// allocation/construction order and both native backends.

struct PlainKey {
    id: Int,
    name: Str,
    active: Bool
}

struct PairBox<T> {
    left: T,
    right: T
}

struct NestedKey<T> {
    pair: PairBox<T>,
    meta: (Int, Bool)
}

struct Inner<T> {
    value: T
}

// The type argument itself is parameterized.  Every derived trait must retain
// evidence for both Inner layers instead of flattening this to the base dict.
struct Outer<T> {
    nested: Inner<Inner<T>>
}

// Fully concrete nesting exercises dict_lower's memoised static wrapper path.
struct StaticOuter {
    nested: Inner<Inner<Int>>
}

// An unconditional generic impl must remain usable even when its type
// argument does not implement the impl's trait.  Dictionary resolution must
// follow the impl predicates, not require the same trait from every type arg.
trait Always {
    fn marker(self) -> Int
}

struct AnyValue<T> {
    value: T
}

impl<T> Always for AnyValue<T> {
    fn marker(self) -> Int { 107 }
}

// Directly recursive struct: the helper is compiled (and therefore its
// derived Hash body/getter is emitted) without constructing an infinite value.
struct RecursiveStruct {
    value: Int,
    next: RecursiveStruct
}

enum Marker {
    First,
    Second,
}

enum Payload<T> {
    Empty,
    Positional(T, T),
    Named { value: T, enabled: Bool },
    Recursive(T, Payload<T>),
}

fn hash_agrees_with_eq<T: Hash + Eq>(a: T, b: T) -> Bool {
    a == b && a.hash() == b.hash()
}

fn compile_recursive_struct_hash(value: RecursiveStruct) -> Int {
    value.hash()
}

fn read_marker<T: Always>(value: T) -> Int {
    value.marker()
}

fn main() {
    assert(read_marker(AnyValue { value: 1.5 }) == 107,
        "unconditional generic impl accepts an unbounded Float argument")

    let p1 = PlainKey { id: 7, name: "seven", active: true }
    let unrelated = PlainKey { id: 99, name: "other", active: false }
    let p2 = PlainKey { id: 7, name: "seven", active: true }
    assert(hash_agrees_with_eq(p1, p2), "plain struct hash follows Eq")
    assert(p1.hash() != unrelated.hash(), "plain field order contributes")

    let n1 = NestedKey {
        pair: PairBox { left: "a", right: "b" },
        meta: (3, true)
    }
    let n2 = NestedKey {
        pair: PairBox { left: "a", right: "b" },
        meta: (3, true)
    }
    assert(hash_agrees_with_eq(n1, n2), "nested generic and tuple hash")

    let o1 = Outer { nested: Inner { value: Inner { value: 21 } } }
    let o2 = Outer { nested: Inner { value: Inner { value: 21 } } }
    let o3 = Outer { nested: Inner { value: Inner { value: 34 } } }
    let copied = o1.clone()
    assert(copied == o1, "nested recursive evidence preserves Clone/Eq")
    assert(o1 < o3, "nested recursive evidence preserves Ord")
    assert(o1.debug().len() > 0, "nested recursive evidence preserves Debug")

    // Repeated calls force the dynamic Inner<T> wrapper inside Outer<T>'s
    // synthetic methods to be constructed and reclaimed many times.
    for _ in 0..128 {
        assert(hash_agrees_with_eq(o1, o2),
            "dynamic nested wrapper Hash/Eq remains stable")
        assert(o1 < o3, "dynamic nested wrapper Ord remains stable")
        assert(o1.debug().len() > 0, "dynamic nested wrapper Debug remains stable")
    }

    let s1 = StaticOuter {
        nested: Inner { value: Inner { value: 55 } }
    }
    let s2 = StaticOuter {
        nested: Inner { value: Inner { value: 55 } }
    }
    for _ in 0..128 {
        assert(hash_agrees_with_eq(s1, s2),
            "static nested wrapper singleton remains stable")
    }

    assert(Marker::First.hash() != Marker::Second.hash(),
        "variant discriminator contributes before fields")

    let e1 = Payload::Recursive(
        1,
        Payload::Named { value: 2, enabled: true }
    )
    let e2 = Payload::Recursive(
        1,
        Payload::Named { value: 2, enabled: true }
    )
    let positional = Payload::Positional(1, 2)
    assert(hash_agrees_with_eq(e1, e2),
        "recursive positional/named enum hash follows Eq")
    assert(e1.hash() != positional.hash(),
        "enum payload decomposition and discriminator are stable")

    let mut map: Map<PlainKey, Str> = map_new()
    map.insert(p1, "found")
    match map.get(p2) {
        some(value) => assert(value == "found", "auto Hash Map lookup"),
        none => assert(false, "auto Hash Map lookup missing"),
    }

    let mut nested_map: Map<Outer<Int>, Str> = map_new()
    nested_map.insert(o1, "nested")
    match nested_map.get(o2) {
        some(value) => assert(value == "nested",
            "recursive evidence supports Map lookup"),
        none => assert(false, "recursive evidence Map lookup missing"),
    }

    let mut nested_set: Set<Outer<Int>> = set_new()
    nested_set.insert(o1)
    nested_set.insert(o2)
    nested_set.insert(o3)
    assert(nested_set.len() == 2,
        "recursive evidence supports Set deduplication")

    let mut set: Set<Payload<Int>> = set_new()
    set.insert(e1)
    set.insert(e2)
    set.insert(positional)
    assert(set.len() == 2, "auto Hash Set deduplicates equal enum values")
    assert(set.contains(Payload::Named { value: 2, enabled: true }) == false,
        "variant discriminator keeps distinct variants separate")

    // Pin representative structural hashes in the golden. The differential
    // lane therefore verifies byte-for-byte hash stability across backends,
    // not merely the Eq => same-hash invariant within each backend.
    print("plain_hash=${p1.hash()}")
    print("nested_hash=${n1.hash()}")
    print("nested_wrapper_hash=${o1.hash()}")
    print("marker_hashes=${Marker::First.hash()},${Marker::Second.hash()}")
    print("recursive_enum_hash=${e1.hash()}")
    print("derive_hash_set: all tests passed")
}
