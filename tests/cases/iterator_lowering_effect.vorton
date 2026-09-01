struct EffectIter { pub value: Int, pub max: Int }

impl Iterator for EffectIter {
    type Item = Int
    fn next(mut self) -> Int? {
        print("next")
        if self.value < self.max {
            let value = self.value
            self.value = self.value + 1
            some(value)
        } else {
            none
        }
    }
}

impl Iterable for EffectIter {
    type Item = Int
    type Iter = EffectIter
    fn iter(self) -> EffectIter {
        print("iter")
        self
    }
}

fn explicit_steps() with {console} {
    let source = EffectIter { value: 0, max: 1 }
    let mut iterator = source.iter()
    match iterator.next() {
        some(value) => print(value),
        none => {}
    }
    let exhausted = iterator.next()
}

fn implicit_steps() with {console} {
    for value in (EffectIter { value: 0, max: 1 }) {
        print(value)
    }
}

fn main() {
    explicit_steps()
    implicit_steps()
}
