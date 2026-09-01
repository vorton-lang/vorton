pub struct Counter {
    pub value: Int
}

impl Counter {
    pub fn adjust(mut self) {
        self.value = self.value + 10
    }

    pub fn read(self) -> Int {
        self.value
    }
}

pub fn make() -> Counter {
    Counter { value: 1 }
}
