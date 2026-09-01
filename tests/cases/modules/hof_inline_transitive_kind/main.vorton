use defs

fn apply(f: fn(Int) -> Int, value: Int) -> Int {
    f(value)
}

fn main() {
    // ValueBindingKind must follow the exact DefId through both inline aliases;
    // the second two-hop path deliberately has the same source/intermediate
    // leaves, so neither provenance nor backend lookup may collapse by suffix.
    print(apply(facade::increment, 41))
    print(apply(facade::decoy_increment, 41))
}
