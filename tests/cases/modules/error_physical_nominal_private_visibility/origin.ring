enum HiddenLeaf {
    Number(Int),
}

pub struct PublicBox {
    hidden: HiddenLeaf,
}
