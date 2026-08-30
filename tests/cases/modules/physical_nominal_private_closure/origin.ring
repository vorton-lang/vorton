enum HiddenLeaf<T> {
    Value(T),
    Link(HiddenLink<T>),
}

struct HiddenLink<T> {
    leaf: HiddenLeaf<T>,
}

type HiddenAlias<T> = HiddenLeaf<T>

pub struct PublicBox<T> {
    hidden: HiddenAlias<T>,
}

pub fn make_public(value: Int) -> PublicBox<Int> {
    PublicBox { hidden: HiddenLeaf::Value(value) }
}

pub fn read_public(value: PublicBox<Int>) -> Int {
    match value.hidden {
        HiddenLeaf::Value(number) => number,
        HiddenLeaf::Link(_) => -1,
    }
}
