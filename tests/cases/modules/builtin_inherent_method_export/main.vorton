// Regression (B-107 5cf55aa review): an inherent impl on a builtin type has
// no Struct/Enum declaration binding anywhere, so its registration key is the
// bare builtin spelling ("Str"). Exports must carry these methods across
// modules instead of fail-closing on the missing plan binding.
use defs::{helper}

fn main() {
    print("hi".shout())
    print(helper())
}
