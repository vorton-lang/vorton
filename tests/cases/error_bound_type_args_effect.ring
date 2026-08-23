trait GenericTrait<T> {}

effect Rejected<T: GenericTrait<Int>> {
    fn read(value: T) -> Unit
}

fn main() {}
