trait Describable {
    fn describe(self) -> Str
}

trait Printable: Describable {
    fn label(self) -> Str
}

struct Item { name: Str, value: Int }

impl Describable for Item {
    fn describe(self) -> Str { self.name }
}

impl Printable for Item {
    fn label(self) -> Str { "${self.name}: ${self.value.to_str()}" }
}

fn show_desc<T: Printable>(x: T) -> Str {
    x.describe()  // Printable implies Describable, so .describe() should work
}

fn show_label<T: Printable>(x: T) -> Str {
    x.label()
}

fn show_both<T: Printable>(x: T) -> Str {
    "${x.describe()} (${x.label()})"
}

fn main() with {console} {
    let item = Item { name: "widget", value: 42 }
    assert(show_desc(item) == "widget", "describe should work through supertrait")
    assert(show_label(item) == "widget: 42", "label should work directly")
    assert(show_both(item) == "widget (widget: 42)", "both should work together")
    print("Supertrait basic: all passed")
}
