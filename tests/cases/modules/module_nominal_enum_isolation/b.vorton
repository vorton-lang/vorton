enum Token {
    Item(Str),
    Empty,
}

pub fn make_token(value: Str) -> Token {
    Token::Item(value)
}

pub fn read_token(token: Token) -> Str {
    match token {
        Token::Item(value) => value,
        Token::Empty => "empty",
    }
}
