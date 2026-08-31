struct DuplicateImplFnExtern {}

impl DuplicateImplFnExtern {
    extern fn clash<T>(self: DuplicateImplFnExtern, value: T) -> Int with {unsafe}
    fn preserved(self) -> Int { 1 }
}

fn main() {}
