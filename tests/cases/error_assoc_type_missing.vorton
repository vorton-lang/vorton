// Missing associated type implementation should report E0510
trait Container {
    type Item
    fn get(self) -> Item
}

struct Box {
    value: Int
}

// Missing: type Item = Int
impl Container for Box {
    fn get(self) -> Int {
        self.value
    }
}
