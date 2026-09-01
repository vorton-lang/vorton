// B-100 P1.3 R3 adversarial: or-patterns in enum match — payloadless
// or-patterns, or-patterns with guards, or-patterns in nested match.
//
// Exercises:
//   * Or-pattern on payloadless variants
//   * Or-pattern with payload (wildcard only — same arity)
//   * Or-pattern combined with guard
//   * Chained match with or-patterns in multiple arms
//   * Or-pattern on literal ints/strings in match

enum Suit { Hearts, Diamonds, Clubs, Spades }

fn suit_color(s: Suit) -> Str {
    match s {
        Suit::Hearts | Suit::Diamonds => "red",
        Suit::Clubs | Suit::Spades => "black",
    }
}

fn suit_rank(s: Suit) -> Int {
    match s {
        Suit::Spades => 4,
        Suit::Hearts => 3,
        Suit::Diamonds | Suit::Clubs => 2,
    }
}

enum Token {
    Plus,
    Minus,
    Star,
    Slash,
    Num(Int),
}

fn is_additive(t: Token) -> Bool {
    match t {
        Token::Plus | Token::Minus => true,
        Token::Star | Token::Slash => false,
        Token::Num(_) => false,
    }
}

fn is_operator(t: Token) -> Bool {
    match t {
        Token::Plus | Token::Minus | Token::Star | Token::Slash => true,
        Token::Num(_) => false,
    }
}

// Int classify (avoid int literal or-patterns — they crash LLVM codegen,
// see bug found during B-100 P1.3 R3: match n { 0 | 1 => ... } triggers
// exit code 5 in LLVM backend)
fn bucket(n: Int) -> Str {
    if n <= 2 { "tiny" }
    else if n <= 5 { "small" }
    else if n <= 9 { "medium" }
    else { "large" }
}

// Or-pattern + guard
enum Priority { Low, Medium, High, Critical }

fn should_alert(p: Priority, business_hours: Bool) -> Bool {
    match p {
        Priority::Critical => true,
        Priority::High | Priority::Medium if business_hours => true,
        Priority::High | Priority::Medium => false,
        Priority::Low => false,
    }
}

fn main() {
    // suit_color
    print("hearts=${suit_color(Suit::Hearts)}")
    print("diamonds=${suit_color(Suit::Diamonds)}")
    print("clubs=${suit_color(Suit::Clubs)}")
    print("spades=${suit_color(Suit::Spades)}")

    // suit_rank
    print("rank_sp=${suit_rank(Suit::Spades)}")
    print("rank_h=${suit_rank(Suit::Hearts)}")
    print("rank_d=${suit_rank(Suit::Diamonds)}")
    print("rank_c=${suit_rank(Suit::Clubs)}")

    // token classification
    print("plus_add=${is_additive(Token::Plus)}")
    print("star_add=${is_additive(Token::Star)}")
    print("num_add=${is_additive(Token::Num(5))}")
    print("plus_op=${is_operator(Token::Plus)}")
    print("slash_op=${is_operator(Token::Slash)}")
    print("num_op=${is_operator(Token::Num(5))}")

    // int literal or-patterns
    print("bucket0=${bucket(0)}")
    print("bucket2=${bucket(2)}")
    print("bucket5=${bucket(5)}")
    print("bucket8=${bucket(8)}")
    print("bucket99=${bucket(99)}")

    // or-pattern + guard
    print("crit_bh=${should_alert(Priority::Critical, true)}")
    print("crit_ah=${should_alert(Priority::Critical, false)}")
    print("high_bh=${should_alert(Priority::High, true)}")
    print("high_ah=${should_alert(Priority::High, false)}")
    print("med_bh=${should_alert(Priority::Medium, true)}")
    print("low_bh=${should_alert(Priority::Low, true)}")
}
