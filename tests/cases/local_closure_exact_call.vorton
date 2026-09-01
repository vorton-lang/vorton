fn choose() -> Int {
    99
}

fn main() {
    {
        let choose = fn() -> Int { 7 }
        print(choose())
    }
    // A prior inner exact slot with the same spelling must not reclassify this
    // later global call as local.
    print(choose())

    let captured = 8
    let read_captured = fn() -> Int { captured }
    print(read_captured())
}
