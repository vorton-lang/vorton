pub extern fn print<T>(value: T) -> Unit with {console}
pub extern fn assert(cond: Bool, msg: Str) -> Unit with {console}
pub extern fn panic(msg: Str) -> Never

pub trait Json {
    fn to_json(self: Self) -> Str
}

fn json_hex_digit(value: Int) -> Str {
    "0123456789abcdef".char_at(value).unwrap_or("0")
}

fn json_escape_string(value: Str) -> Str {
    let mut out = string_builder()
    out.add("\"")
    let mut i = 0
    while i < value.len() {
        let code = value.char_code_at(i).unwrap_or(0)
        if code == 34 {
            out.add("\\\"")
        } else if code == 92 {
            out.add("\\\\")
        } else if code == 8 {
            out.add("\\b")
        } else if code == 12 {
            out.add("\\f")
        } else if code == 10 {
            out.add("\\n")
        } else if code == 13 {
            out.add("\\r")
        } else if code == 9 {
            out.add("\\t")
        } else if code < 32 {
            out.add("\\u00")
            out.add(json_hex_digit(code / 16))
            out.add(json_hex_digit(code % 16))
        } else {
            out.add(value.char_at(i).unwrap_or(""))
        }
        i = i + 1
    }
    out.add("\"")
    out.to_str()
}

impl Json for Int {
    fn to_json(self) -> Str {
        self.to_str()
    }
}

impl Json for Float {
    fn to_json(self) -> Str {
        let text = self.to_str()
        if text == "NaN" || text == "Infinity" || text == "-Infinity" {
            "null"
        } else {
            text
        }
    }
}

impl Json for Bool {
    fn to_json(self) -> Str {
        if self { "true" } else { "false" }
    }
}

impl Json for Str {
    fn to_json(self) -> Str {
        json_escape_string(self)
    }
}

pub fn json_stringify<T: Json>(value: T) -> Str {
    value.to_json()
}
