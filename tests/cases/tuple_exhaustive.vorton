// Test tuple exhaustiveness: all cross-column combinations must be covered
fn check_pair(x: (Bool, Bool)) -> Str {
    match x {
        (true, true) => "tt",
        (true, false) => "tf",
        (false, true) => "ft",
        (false, false) => "ff",
    }
}

fn check_with_wildcard(x: (Bool, Bool)) -> Str {
    match x {
        (true, _) => "t*",
        (false, _) => "f*",
    }
}

fn check_mixed(x: (Bool, Bool)) -> Str {
    match x {
        (true, true) => "tt",
        (_, false) => "xf",
        (false, true) => "ft",
    }
}

fn main() {
    print(check_pair((true, false)))
    print(check_pair((false, true)))
    print(check_with_wildcard((true, true)))
    print(check_with_wildcard((false, false)))
    print(check_mixed((true, false)))
    print(check_mixed((false, true)))
}
// expect: tf
// expect: ft
// expect: t*
// expect: f*
// expect: xf
// expect: ft
