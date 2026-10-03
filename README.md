# Vorton

Vorton 是一门给 LLM 写、给人定边界的 native 语言：代码主要由 agent 产出，正确性由编译器保证，人只掌握模块、接口与能力这一层。设计公理见[设计哲学](docs/philosophy.md)。

编译器用 Rust 编写，经 C11 生成 native 程序。目标与顺序见 [GitHub Milestones](https://github.com/vorton-lang/vorton/milestones)。

## 现在能运行的程序

数据分两种。值（`Int`、`Str`、只含值的 struct 等）赋值就是拷贝；实体（`List`、`Map`、`Set` 与含有它们的类型）赋值是移交，要副本就显式 `clone()`。要修改调用方的数据，签名和调用处都写 `&mut`，写法与 Rust 相同；编译器保证一个位置被修改时没有别处在读它。

```vorton
struct Enemy { name: Str, hp: Int }

impl Enemy {
    fn hit(&mut self, amount: Int) {
        self.hp -= amount
    }
}

fn damage_all(enemies: &mut List<Enemy>, amount: Int) {
    for e in &mut enemies {
        e.hit(amount)
    }
}

fn main() {
    let mut enemies = [Enemy { name: "slime", hp: 10 }, Enemy { name: "bat", hp: 4 }]
    let before = enemies.clone()
    damage_all(&mut enemies, 3)
    let mut hp: Map<Str, Int> = Map::new()
    for e in &enemies {
        hp[e.name] = e.hp
    }
    print("${before[0].hp} -> ${hp["slime"]}")   // 10 -> 7
}
```

```text
cargo run --bin vorton -- run program.vorton
```

需要 clang 或 gcc；也可以用 `VORTON_CC` 指定 C 编译器。当前支持的范围见[编译器设计](docs/design.md#当前支持范围)，完整规则见[语言规范](docs/lang-spec/README.md)。

## 检查

本地检查与 CI 运行同样三项：

```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
```

`cargo test` 会把 [`tests/run/`](tests/run) 下的每个程序编译成 native 并比对输出，所以同样需要 C 编译器。

## 参与工作

角色、用户保留事项与维护方式见 [`AGENTS.md`](AGENTS.md) 和 [`MAINTAINING.md`](MAINTAINING.md)。

## 文档

- [设计哲学](docs/philosophy.md)：语言公理与仲裁依据
- [语言规范](docs/lang-spec/README.md)：公开语法与语义
- [编译器设计](docs/design.md)：管线、runtime 与测试
- [Agent 入口](AGENTS.md)：角色、仲裁顺序与用户保留事项
- [维护手册](MAINTAINING.md)：日常工作、记录、汇报与外包派发
- [审计指引](AUDITING.md)：外部审计查什么、怎么挂 Issue
