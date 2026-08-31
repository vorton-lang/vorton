fn main() with {console} {
    let empty: List<Int> = []

    match empty.last() {
        some(v) => assert(false, "last of empty should be none"),
        none => {}
    }

    match empty.first() {
        some(v) => assert(false, "first of empty should be none"),
        none => {}
    }

    let list = [10, 20, 30]
    match list.last() {
        some(v) => assert(v == 30, "last should be 30"),
        none => assert(false, "last should not be none")
    }

    match list.first() {
        some(v) => assert(v == 10, "first should be 10"),
        none => assert(false, "first should not be none")
    }

    print("List first/last empty: all passed")
}
