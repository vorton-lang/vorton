use defs
use defs::{keep_after}

fn main() {
    // keep_after is raw Item -> raw Item even though it appears after facade.
    // The ordinary re-exported nominal must remain a distinct function type.
    let wrong: fn(facade::Item) -> facade::Item = keep_after
}
