use lib::incompatible_shadow

fn map_get_panic(_: Map<Int, Int>, _: Int) -> Int { -777 }

fn compatible_shadow() -> Int {
    let m = map_from([(1, 11)])
    m[1]
}

fn main() {
    print(compatible_shadow())
    print(incompatible_shadow())
}
