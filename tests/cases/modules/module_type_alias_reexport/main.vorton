use transitive::{Count, Identity}
use decoy::{Identity as WrongIdentity}

fn twice(value: Count) -> Count {
    value * 2
}

fn same(value: Identity<Str>) -> Identity<Str> { value }
fn size(values: WrongIdentity<Int>) -> Int { values.len() }

fn main() {
    print(twice(21))
    print(same("ok"))
    print(size([1, 2, 3]))
}
