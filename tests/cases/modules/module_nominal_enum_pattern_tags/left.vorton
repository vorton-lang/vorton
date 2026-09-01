pub enum Signal {
    First(Int),
    Text(Str),
    Empty,
}

fn guarded(value: Signal) -> Str {
    match value {
        Signal::First(n) if n > 10 => "L:first:${n}",
        Signal::First(n) => "L:small:${n}",
        Signal::Text(s) if s == "left" => "L:text:${s}",
        Signal::Text(s) => "L:other:${s}",
        Signal::Empty => "L:empty",
    }
}

fn nested(value: Signal) -> Str {
    match value {
        Signal::First(n) => match n {
            11 => "L:nested:first",
            _ => "L:nested:first-other",
        },
        Signal::Text(s) => match s {
            "left" => "L:nested:text",
            _ => "L:nested:text-other",
        },
        Signal::Empty => "L:nested:empty",
    }
}

pub fn run() {
    print(guarded(Signal::First(11)))
    print(guarded(Signal::Text("left")))
    print(guarded(Signal::Empty))
    print(nested(Signal::First(11)))
    print(nested(Signal::Text("left")))
    print(nested(Signal::Empty))
}
