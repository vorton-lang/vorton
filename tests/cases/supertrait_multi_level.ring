trait Base {
    fn base_val(self) -> Int
}
trait Mid: Base {
    fn mid_val(self) -> Int
}
trait Top: Mid {
    fn top_val(self) -> Int
}

struct MyStruct { v: Int }

impl Base for MyStruct {
    fn base_val(self) -> Int { self.v }
}
impl Mid for MyStruct {
    fn mid_val(self) -> Int { self.v * 2 }
}
impl Top for MyStruct {
    fn top_val(self) -> Int { self.v * 3 }
}

fn use_top<T: Top>(x: T) -> Int {
    x.base_val() + x.mid_val() + x.top_val()
}

fn main() with {console} {
    let s = MyStruct { v: 10 }
    assert(use_top(s) == 60, "10 + 20 + 30 = 60")
    print("Supertrait multi-level: all passed")
}
