struct Version { major: Int, minor: Int }

fn main() {
    let v1 = Version { major: 1, minor: 0 }
    let v2 = Version { major: 1, minor: 5 }
    let v3 = Version { major: 2, minor: 0 }
    assert(v1 < v2, "1.0 < 1.5")
    assert(v2 < v3, "1.5 < 2.0")
    assert(v3 > v1, "2.0 > 1.0")
    assert(v1 <= v1, "1.0 <= 1.0")
    assert(v1 >= v1, "1.0 >= 1.0")
    assert(1 < 2, "primitive int ord still works")
    print("ord_struct: all tests passed")
}
