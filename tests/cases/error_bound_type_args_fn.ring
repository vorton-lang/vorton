trait GenericTrait<T> {}

fn rejected<T: GenericTrait<Int>>(value: T) -> Unit {}

fn main() {}
