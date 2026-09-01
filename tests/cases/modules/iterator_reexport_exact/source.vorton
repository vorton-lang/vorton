pub struct ModuleIter {
    pub value: Int,
    pub limit: Int
}

impl Iterator for ModuleIter {
    type Item = Int
    fn next(mut self) -> Int? {
        if self.value < self.limit {
            let value = self.value
            self.value = self.value + 1
            some(value)
        } else {
            none
        }
    }
}

pub struct ModuleSource { pub limit: Int }

impl Iterable for ModuleSource {
    type Item = Int
    type Iter = ModuleIter
    fn iter(self) -> ModuleIter {
        ModuleIter { value: 0, limit: self.limit }
    }
}
