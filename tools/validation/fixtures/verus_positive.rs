use vstd::prelude::*;

verus! {

proof fn addition_is_commutative(left: int, right: int)
    ensures
        left + right == right + left,
{
}

fn main() {
}

}
