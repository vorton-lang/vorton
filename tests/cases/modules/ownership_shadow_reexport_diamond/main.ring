use direct_first::{run as run_direct_first}
use alias_first::{run as run_alias_first}

fn main() {
    let mut value = 0
    run_direct_first(value)
    run_alias_first(value)
    print(value)
}
