pub struct Provider {}

impl Provider {
    fn factory(self) -> fn(Int) -> Option<Int> {
        fn(value: Int) -> Option<Int> { some(value + 1) }
    }
}

pub fn provider() -> Provider {
    Provider {}
}
