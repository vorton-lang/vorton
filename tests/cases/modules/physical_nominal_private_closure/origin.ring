enum HiddenLeaf {
    Number(Int),
    Text(Str),
}

struct HiddenBox {
    value: HiddenLeaf,
}

pub struct PublicBox {
    hidden: HiddenBox,
}

pub fn make_public(value: Int) -> PublicBox {
    PublicBox { hidden: HiddenBox { value: HiddenLeaf::Number(value) } }
}

pub fn read_public(value: PublicBox) -> Int {
    match value.hidden.value {
        HiddenLeaf::Number(number) => number,
        HiddenLeaf::Text(_) => -1,
    }
}
