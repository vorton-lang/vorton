// B-140: Multi-segment relative path imports
// use super::a::{Foo} should resolve "a" as intermediate path segment

mod parent {
    pub mod child {
        pub fn value() -> Int { 42 }
        pub fn helper() -> Int { 10 }
    }

    mod consumer {
        // Multi-segment relative path with NamedItems
        use super::child::{value, helper}

        pub fn test_named_items() -> Int { value() + helper() }
    }

    // Module import through intermediate path (use super::child::value)
    mod consumer2 {
        use super::child::value

        pub fn test_module_import() -> Int { value() }
    }

    pub fn run_consumer() -> Int { consumer::test_named_items() }
    pub fn run_consumer2() -> Int { consumer2::test_module_import() }
}

// Deeper nesting: super::super with intermediate segments
mod outer {
    pub mod utils {
        pub fn double(x: Int) -> Int { x * 2 }
    }

    mod middle {
        mod inner {
            // Two levels up, then into utils
            use super::super::utils::{double}

            pub fn test_deep() -> Int { double(21) }
        }

        pub fn run_inner() -> Int { inner::test_deep() }
    }

    pub fn run() -> Int { middle::run_inner() }
}

fn main() {
    assert(parent::run_consumer() == 52, "super::child::{value, helper}")
    assert(parent::run_consumer2() == 42, "super::child::value module import")
    assert(outer::run() == 42, "super::super::utils::{double}")
    print("mod_relative_path_multi: all tests passed")
}
