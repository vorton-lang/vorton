trait AssocBeforeMethods {
    type Item
    fn keep(mut self, mut before_value: Item) -> Item
}

trait AssocBetweenMethods {
    fn first(self, mut count: Int) -> Int
    type Item
    fn second(mut self, mut between_value: Item) -> Item
}

fn main() {
    print("trait method identity assoc order: ok")
}
