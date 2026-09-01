// Test: struct with single field (minimal struct)
// NOTE: Empty struct `Foo {}` has parsing ambiguity (block vs struct literal)
//       so we test with a single field instead

struct Tag { label: Str }

impl Tag {
    fn describe(self) -> Str { "tag:${self.label}" }
}

fn identity(t: Tag) -> Tag {
    t
}

fn main() {
    let t = Tag { label: "x" }
    assert(t.describe() == "tag:x", "single field struct method")

    let t2 = identity(t)
    assert(t2.describe() == "tag:x", "struct passed to fn")

    print("struct_empty: all tests passed")
}
