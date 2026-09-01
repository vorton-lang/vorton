use defs
use defs::{
    imported_value as named_value,
    ImportedItem as NamedItem
}

fn imported_value() -> Int { 10 }
struct ImportedItem { local_wildcard: Int }

fn named_value() -> Int { 20 }
struct NamedItem { local_named: Int }

fn root_exercise() -> Int {
    let wildcard_item = ImportedItem { local_wildcard: 1 }
    let named_item = NamedItem { local_named: 2 }
    imported_value() + named_value() +
        wildcard_item.local_wildcard + named_item.local_named
}

pub mod nested {
    use defs
    use defs::{
        imported_value as named_value,
        ImportedItem as NamedItem
    }

    fn imported_value() -> Int { 30 }
    struct ImportedItem { nested_wildcard: Int }

    fn named_value() -> Int { 40 }
    struct NamedItem { nested_named: Int }

    pub fn exercise() -> Int {
        let wildcard_item = ImportedItem { nested_wildcard: 3 }
        let named_item = NamedItem { nested_named: 4 }
        imported_value() + named_value() +
            wildcard_item.nested_wildcard + named_item.nested_named
    }
}

fn main() {
    print(root_exercise())
    print(nested::exercise())
}
