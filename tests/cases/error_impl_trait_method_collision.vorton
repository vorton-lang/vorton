trait LeftIter {
    fn iter(self) -> Int
}

trait RightIter {
    fn iter(self) -> Str
}

struct TraitCollision {}

impl LeftIter for TraitCollision {
    fn iter(self) -> Int { 1 }
}

impl RightIter for TraitCollision {
    fn iter(self) -> Str { "two" }
}

fn main() {}
