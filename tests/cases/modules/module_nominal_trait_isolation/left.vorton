pub trait Render {
    fn render(self) -> Str
}

pub struct Item { value: Int }

impl Render for Item {
    fn render(self) -> Str { "left:${self.value}" }
}

fn render_generic<T: Render>(value: T) -> Str { value.render() }

pub fn run() { print(render_generic(Item { value: 11 })) }
