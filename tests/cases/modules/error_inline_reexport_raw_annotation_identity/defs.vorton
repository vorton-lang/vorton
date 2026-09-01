pub extern type Item
pub type Raw = Item

pub fn raw_identity(value: Raw) -> Raw { value }
pub fn keep_before(value: Item) -> Item { raw_identity(value) }

pub mod facade {
    pub use super::origin::Item
}

mod origin {
    pub struct Item { value: Int }
}

pub fn keep_after(value: Item) -> Item { raw_identity(value) }
