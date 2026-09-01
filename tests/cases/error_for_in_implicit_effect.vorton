struct NoisyIter { pub value: Int }

impl Iterator for NoisyIter {
    type Item = Int
    fn next(mut self) -> Int? {
        print("next")
        none
    }
}

impl Iterable for NoisyIter {
    type Item = Int
    type Iter = NoisyIter
    fn iter(self) -> NoisyIter {
        print("iter")
        self
    }
}

fn pure_loop() with {} {
    for value in (NoisyIter { value: 0 }) {}
}

fn main() {}
