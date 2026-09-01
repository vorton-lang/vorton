// Generic function calling another generic function — dictionary forwarding
trait ToStr {
    fn to_str(self) -> Str
}

struct Num { val: Int }

impl ToStr for Num {
    fn to_str(self) -> Str { "num" }
}

fn stringify<T: ToStr>(x: T) -> Str {
    x.to_str()
}

fn show<T: ToStr>(x: T) -> Str {
    stringify(x)
}

fn main() {
    print(show(Num { val: 1 }))
}
