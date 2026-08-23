trait RootLabel {
    fn root(self) -> Str
}

trait LeftLabelled: RootLabel {
    fn left(self) -> Str
}

trait RightLabelled: RootLabel {
    fn right(self) -> Str
}

struct LeftSource {}
struct RightSource {}

impl RootLabel for LeftSource {
    fn root(self) -> Str { "root-left" }
}

impl LeftLabelled for LeftSource {
    fn left(self) -> Str { "left" }
}

impl RootLabel for RightSource {
    fn root(self) -> Str { "root-right" }
}

impl RightLabelled for RightSource {
    fn right(self) -> Str { "right" }
}

struct SharedSuperDelegate {
    left_source: LeftSource,
    right_source: RightSource,
}

impl SharedSuperDelegate {
    fn local_before(self) -> Int { 1 }
    delegate left_source: LeftLabelled
    fn local_between(self) -> Int { 2 }
    delegate right_source: RightLabelled
}

fn main() {
    let value = SharedSuperDelegate {
        left_source: LeftSource {},
        right_source: RightSource {},
    }
    print(value.root())
    print(value.left())
    print(value.right())
}
