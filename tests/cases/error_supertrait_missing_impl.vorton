// expect: error
// expect: supertrait
trait Describable {
    fn describe(self) -> Str
}
trait Printable: Describable {
    fn label(self) -> Str
}
struct Foo { x: Int }
// Missing impl Describable for Foo!
impl Printable for Foo {
    fn label(self) -> Str { self.x.to_str() }
}
fn main() {}
