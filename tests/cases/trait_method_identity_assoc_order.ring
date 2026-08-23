trait AssocBeforeMethods {
    type Item
    fn keep(mut self, mut before_value: Item) -> Item {
        before_value
    }
}

trait AssocBetweenMethods {
    fn first(self, mut count: Int) -> Int {
        count + 1
    }
    type Item
    fn second(mut self, mut between_value: Item) -> Item {
        between_value
    }
}

fn main() {
    print("trait method identity assoc order: ok")
}
