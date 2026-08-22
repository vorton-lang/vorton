use dep::{tick}

struct SharedName { value: Int }
enum SharedName { Variant }
type SharedName = Int

effect SharedEffect {
    fn operation(value: Int) -> Int
}
effect alias SharedEffect = {io}

trait MemberTrait {
    fn shared_member(self) -> Int
}
effect MemberEffect {
    fn shared_member(value: Int) -> Int
}
struct MemberHost {}
impl MemberHost {
    fn shared_member(self) -> Int { 1 }
}
impl MemberHost {
    fn other_member(self) -> Int { 2 }
}

test "duplicate description is not a binding" {}
test "duplicate description is not a binding" {}

fn main() {
    print(tick())
}
