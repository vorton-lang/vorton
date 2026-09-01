enum Shadow {
    some(Int),
    idle
}

struct ProtocolIter {
    pub value: Int,
    pub limit: Int
}

impl Iterator for ProtocolIter {
    type Item = Int
    fn next(mut self) -> Int? {
        print("trait-next")
        if self.value < self.limit {
            let value = self.value
            self.value = self.value + 1
            let present = [value]
            present.get(0)
        } else {
            let exhausted: List<Int> = []
            exhausted.get(0)
        }
    }
}

struct DropSource {
    pub limit: Int
}

impl Drop for DropSource {
    fn drop(self) {
        print("drop-source")
    }
}

impl Iterable for DropSource {
    type Item = Int
    type Iter = ProtocolIter
    fn iter(self) -> ProtocolIter {
        print("trait-iter")
        ProtocolIter { value: 0, limit: self.limit }
    }
}

fn main() {
    let shadow = Shadow::some(99)
    match shadow {
        Shadow::some(value) => print("shadow=${value}"),
        Shadow::idle => print("shadow=idle")
    }

    let source = DropSource { limit: 2 }
    for value in source {
        print("value=${value}")
    }
    print("after-loop")
}
