enum PositionalChoice {
    PositionalLeft(Int),
    PositionalRight(Int),
}

enum TupleChoice {
    TupleLeft((Int, Int)),
    TupleRight((Int, Int)),
}

enum NamedChoice {
    NamedLeft { value: Int, marker: Int },
    NamedRight { marker: Int, value: Int },
}

fn positional_value(choice: PositionalChoice) -> Int {
    match choice {
        PositionalLeft(value) | PositionalRight(value) if value > 0 => {
            let read_value = fn() -> Int { value }
            read_value()
        },
        _ => -1,
    }
}

fn tuple_value(choice: TupleChoice) -> Int {
    match choice {
        TupleLeft((value, _)) | TupleRight((value, _)) => value,
    }
}

fn named_value(choice: NamedChoice) -> Int {
    match choice {
        NamedLeft { value, marker: _ } |
        NamedRight { marker: _, value } => value,
    }
}

fn main() {
    print(positional_value(PositionalLeft(1)))
    print(positional_value(PositionalRight(2)))
    print(tuple_value(TupleLeft((3, 30))))
    print(tuple_value(TupleRight((4, 40))))
    print(named_value(NamedLeft { value: 5, marker: 50 }))
    print(named_value(NamedRight { marker: 60, value: 6 }))
}
