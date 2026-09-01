pub enum Signal {
    Empty,
    Text(Str),
    First(Int),
}

fn guarded(value: Signal) -> Str {
    match value {
        Signal::Empty => "R:empty",
        Signal::Text(s) if s == "right" => "R:text:${s}",
        Signal::Text(s) => "R:other:${s}",
        Signal::First(n) if n > 20 => "R:first:${n}",
        Signal::First(n) => "R:small:${n}",
    }
}

fn nested(value: Signal) -> Str {
    match value {
        Signal::Empty => "R:nested:empty",
        Signal::Text(s) => match s {
            "right" => "R:nested:text",
            _ => "R:nested:text-other",
        },
        Signal::First(n) => match n {
            22 => "R:nested:first",
            _ => "R:nested:first-other",
        },
    }
}

pub fn run() {
    print(guarded(Signal::Empty))
    print(guarded(Signal::Text("right")))
    print(guarded(Signal::First(22)))
    print(nested(Signal::Empty))
    print(nested(Signal::Text("right")))
    print(nested(Signal::First(22)))
}
