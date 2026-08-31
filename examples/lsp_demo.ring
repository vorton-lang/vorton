// Ring-lang LSP Demo
// 用 VSCode 打开此文件体验全部 LSP 功能：
// 悬停查看类型、Ctrl+Click 跳转定义、补全、重命名、大纲视图

// === Struct + Trait ===

struct User { name: Str, age: Int }

trait Greetable {
    fn greet(self) -> Str
}

impl Greetable for User {
    fn greet(self) -> Str { "hello, ${self.name}" }
}

fn show<T: Greetable>(x: T) -> Str {
    x.greet()
}

// === Enum + Pattern Matching ===

enum Shape {
    circle(Int),
    rect(Int, Int),
}

fn area(s: Shape) -> Int {
    match s {
        circle(r) => r * r * 3,
        rect(w, h) => w * h,
    }
}

// === Effect System + Handler ===

effect FileAccess {
    fn read(path: Str) -> Str
}

fn read_config() -> Str {
    FileAccess.read("config.toml")
}

fn load_data() -> Str {
    let config = handle {
        read_config()
    } with {
        FileAccess.read(path) => "mock:${path}",
    }
    config
}

// === Option<T> + ? + catch ===

fn find(x: Int) -> Int? {
    if x > 0 { some(x) } else { none }
}

fn safe_add(a: Int, b: Int) -> Int {
    let result = some(find(a)? + find(b)?) catch { _ => none }
    result.unwrap_or(0)
}

// === Row Polymorphism ===

fn get_name(r: {name: Str, ..rest}) -> Str {
    r.name
}

// === 主函数 ===

fn main() {
    let user = User { name: "Alice", age: 30 }
    let greeting = show(user)
    let shape = circle(5)
    let size = area(shape)
    let data = load_data()
    let score = safe_add(10, 20)
    let name = get_name(user)

    print("${greeting}, area=${size}")
    print("data=${data}, score=${score}, name=${name}")
}
