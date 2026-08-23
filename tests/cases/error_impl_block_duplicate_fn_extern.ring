struct DuplicateImplFnExtern {}

impl DuplicateImplFnExtern {
    extern fn clash(self) -> Int
}

fn main() {}
