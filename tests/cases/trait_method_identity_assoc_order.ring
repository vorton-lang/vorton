trait AssocBeforeMethods {
    type Item
    fn get(self) -> Item
}

trait AssocBetweenMethods {
    fn first(self) -> Int
    type Item
    fn second(self) -> Item
}

fn main() {
    print("trait method identity assoc order: ok")
}
