// Regression (B-107 5cf55aa review): an inherent impl inside a pub inline mod
// must export its methods under the canonical target identity the checker
// registered (pkg$$_inner::Gadget), not silently drop them because the
// post-rollback environment no longer answers the prefixed spelling.
use defs

fn main() {
    print(inner::make(3).spin())
}
