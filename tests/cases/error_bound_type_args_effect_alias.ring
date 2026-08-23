trait GenericTrait<T> {}

effect alias Rejected<T: GenericTrait<Int>> = {io}

fn main() {}
