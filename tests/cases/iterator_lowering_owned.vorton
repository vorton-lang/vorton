struct OwnedItem { pub name: Str }

struct OwnedIter {
    pub items: List<OwnedItem>,
    pub index: Int
}

impl Iterator for OwnedIter {
    type Item = OwnedItem
    fn next(mut self) -> OwnedItem? {
        if self.index < self.items.len() {
            let value = self.items.get(self.index)
            self.index = self.index + 1
            value
        } else {
            none
        }
    }
}

impl Iterable for OwnedIter {
    type Item = OwnedItem
    type Iter = OwnedIter
    fn iter(self) -> OwnedIter { self }
}

fn owned(prefix: Str) -> OwnedIter {
    OwnedIter {
        items: [
            OwnedItem { name: "${prefix}-0" },
            OwnedItem { name: "${prefix}-1" },
            OwnedItem { name: "${prefix}-2" }
        ],
        index: 0
    }
}

fn first_owned() -> OwnedItem {
    for item in owned("return") {
        return item
    }
    OwnedItem { name: "missing" }
}

fn main() {
    for item in owned("normal") {
        print(item.name)
    }

    for item in owned("break") {
        print(item.name)
        break
    }

    for item in owned("continue") {
        if item.name == "continue-1" { continue }
        print(item.name)
    }

    let escaped = first_owned()
    print(escaped.name)
}
