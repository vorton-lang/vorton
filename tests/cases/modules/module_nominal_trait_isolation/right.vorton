pub trait Render {
    fn render(self) -> Str
}

pub struct Item { label: Str, code: Int }

impl Render for Item {
    fn render(self) -> Str { "right:${self.label}:${self.code}" }
}

fn render_generic<T: Render>(value: T) -> Str { value.render() }

pub fn run() { print(render_generic(Item { label: "R", code: 22 })) }
