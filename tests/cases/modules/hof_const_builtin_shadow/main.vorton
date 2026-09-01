use constants::{print as const_print, Cell as const_cell, direct_getters, two_hop_print}

fn apply(f: fn(Int) -> Int, value: Int) -> Int {
    f(value)
}

fn main() {
    print(direct_getters(40))
    print(apply(const_print, 40))
    print(apply(const_cell, 40))
    print(apply(two_hop_print(), 40))
}
