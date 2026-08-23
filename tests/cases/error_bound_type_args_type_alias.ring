trait GenericTrait<T> {}

type Rejected<T: GenericTrait<Int>> = T

fn main() {}
