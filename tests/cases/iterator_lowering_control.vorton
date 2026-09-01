struct TraceIter {
    pub name: Str,
    pub value: Int,
    pub max: Int
}

impl Iterator for TraceIter {
    type Item = Int
    fn next(mut self) -> Int? {
        print("${self.name}:next:${self.value}")
        if self.value < self.max {
            let value = self.value
            self.value = self.value + 1
            some(value)
        } else {
            none
        }
    }
}

impl Iterable for TraceIter {
    type Item = Int
    type Iter = TraceIter
    fn iter(self) -> TraceIter {
        print("${self.name}:iter")
        self
    }
}

fn make_trace(name: Str, max: Int) -> TraceIter {
    print("${name}:make")
    TraceIter { name: name, value: 0, max: max }
}

fn return_early() -> Int {
    for value in make_trace("return", 4) {
        if value == 1 { return value }
    }
    -1
}

fn main() {
    for value in make_trace("control", 4) {
        if value == 0 { continue }
        print("control:use:${value}")
        if value == 2 { break }
    }

    print("returned:${return_early()}")

    for outer in make_trace("outer", 2) {
        print("outer:use:${outer}")
        for inner in make_trace("inner${outer}", 1) {
            print("pair:${outer}:${inner}")
        }
    }
}
