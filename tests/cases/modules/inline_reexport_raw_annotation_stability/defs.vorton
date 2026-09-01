// Audit #259 regression: an inline re-export with the same leaf name must not
// leak its ordinary nominal type into the surrounding raw extern namespace.
pub extern type Item
pub type Raw = Item

pub fn raw_identity(value: Raw) -> Raw { value }
pub fn keep_before(value: Item) -> Item { raw_identity(value) }

// Deliberately precedes its private source module. Dependency registration may
// expose origin::Item while checking this frame, but exiting the frame must
// restore the top-level raw Item binding before keep_after is checked.
pub mod facade {
    pub use super::origin::Item
}

mod origin {
    pub struct Item { value: Int }
}

pub fn keep_after(value: Item) -> Item { raw_identity(value) }
