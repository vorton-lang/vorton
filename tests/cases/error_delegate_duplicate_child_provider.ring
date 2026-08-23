trait Labelled {
    fn label(self) -> Str
}

struct LeftLabel {}
struct RightLabel {}

impl Labelled for LeftLabel {
    fn label(self) -> Str { "left" }
}

impl Labelled for RightLabel {
    fn label(self) -> Str { "right" }
}

struct DuplicateDelegate {
    left: LeftLabel,
    right: RightLabel,
}

impl DuplicateDelegate {
    delegate left: Labelled
    delegate right: Labelled
}

fn main() {}
