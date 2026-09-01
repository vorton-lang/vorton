mod outer {
    pub fn value() -> Int { 42 }
    pub fn helper() -> Int { 10 }

    mod inner {
        // Test super:: as use import
        use super::value

        pub fn get_outer() -> Int { value() }
    }

    mod sibling {
        // Test super:: multi-import
        use super::{value, helper}

        pub fn combined() -> Int { value() + helper() }
    }

    // Test super:: in expression context
    mod expr_test {
        pub fn expr_access() -> Int { super::value() }
    }

    pub fn test_inner() -> Int { inner::get_outer() }

    pub fn test_sibling() -> Int { sibling::combined() }

    pub fn test_expr() -> Int { expr_test::expr_access() }
}

fn main() {
    assert(outer::test_inner() == 42, "super:: use import")
    assert(outer::test_sibling() == 52, "super:: multi-import")
    assert(outer::test_expr() == 42, "super:: expr access")
    print("mod_relative_path: all tests passed")
}
