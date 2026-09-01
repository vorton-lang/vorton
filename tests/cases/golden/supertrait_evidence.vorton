// B-100 P1.1: supertrait + evidence chain parity — calling supertrait methods
// through a subtrait bound, multi-level supertrait hierarchy, and evidence
// threading through generic dispatch.
//
// NOTE: does NOT use default trait methods (LLVM pre-existing limitation).

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
    fn label(self) -> Str { "${self.name}:${self.value}" }
}

// call supertrait method via subtrait bound
fn show_desc<T: Printable>(x: T) -> Str {
    x.describe()
}

fn show_label<T: Printable>(x: T) -> Str {
    x.label()
}

fn show_both<T: Printable>(x: T) -> Str {
    "${x.describe()} (${x.label()})"
}

// multi-level supertrait: Base <- Mid <- Top
trait Base {
    fn base_val(self) -> Int
}
trait Mid: Base {
    fn mid_val(self) -> Int
}
trait Top: Mid {
    fn top_val(self) -> Int
}

struct Widget { v: Int }
impl Base for Widget {
    fn base_val(self) -> Int { self.v }
}
impl Mid for Widget {
    fn mid_val(self) -> Int { self.v * 2 }
}
impl Top for Widget {
    fn top_val(self) -> Int { self.v * 3 }
}

// call all three levels through Top bound
fn use_top<T: Top>(x: T) -> Int {
    x.base_val() + x.mid_val() + x.top_val()
}

// call only base through Mid bound
fn use_mid<T: Mid>(x: T) -> Int {
    x.base_val() + x.mid_val()
}

fn main() {
    let item = Item { name: "widget", value: 42 }

    // supertrait method via subtrait bound
    print(show_desc(item))
    print(show_label(item))
    print(show_both(item))

    // multi-level supertrait
    let w = Widget { v: 10 }
    print(use_top(w))
    print(use_mid(w))

    // direct method call (not through generic)
    print(item.describe())
    print(item.label())
    print(w.base_val())
}
