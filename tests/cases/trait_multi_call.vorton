// Trait method called multiple times in same expression
trait Sizeable {
    fn size(self) -> Int
}

struct Box { w: Int, h: Int }

impl Sizeable for Box {
    fn size(self) -> Int { self.w * self.h }
}

fn double_size<T: Sizeable>(x: T) -> Int {
    x.size() + x.size()
}

fn main() {
    print(double_size(Box { w: 3, h: 4 }))
}
