pub trait Render {
    fn render(self) -> Str
}

pub struct Foo { value: Int }

impl Render for Foo {
    fn render(self) -> Str { "foo:${self.value}" }
}
