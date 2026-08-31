trait GenericTrait<T> {}

effect alias Rejected<T: GenericTrait<Int>> = {console}

fn main() {}
