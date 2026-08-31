# Ring

Ring 是一门“不信任程序员”的 native 编程语言：源码保持接近 Python 的低标注体验，编译器负责推断类型、effect、trait 约束与资源行为，并把无法证明的边界显式暴露出来。

编译器已经用 Ring 自举，并只保留 C11 native 后端。单文件、project/module、self-host 与 tracked bootstrap 都使用同一条 C11 管线；测试入口是零第三方 Python runner。

## 语言一瞥

```ring
enum Shape {
    circle(radius: Float),
    rect(width: Float, height: Float),
}

fn area(shape: Shape) -> Float {
    match shape {
        circle(r) => 3.14159 * r * r,
        rect(w, h) => w * h,
    }
}

fn main() {
    let shapes = [circle(2.0), rect(3.0, 4.0)]
    let total = shapes.fold(0.0, fn(sum, shape) { sum + area(shape) })
    print("total = ${total}")
}
```

Effect 也参与推断，并可由词法 handler 替换：

```ring
effect Greeting {
    fn word() -> Str;
}

fn greet() -> Str with {Greeting} {
    "${Greeting.word()}, Ring"
}

fn main() {
    let message = handle { greet() } with {
        Greeting.word() => "hello",
    }
    print(message)
}
```

## Native 构建与运行

当前开发环境以 Windows、Python、Clang/Clang++ 和 lld 为基线。以下命令均从仓库根目录运行。

```powershell
# 从 tracked C bootstrap anchor 构建编译器
.\compiler\scripts\build_native.ps1

# 检查、编译、链接并运行一个程序
.\ring.exe check examples/hello.ring
.\ring.exe build examples/hello.ring --target=c
clang++ -c ring_runtime.cpp -o ring_runtime.o -std=c++17 -O2 -D_CRT_SECURE_NO_WARNINGS
clang examples/hello.o ring_runtime.o -o examples/hello.exe -lmsvcrt "-Wl,/STACK:536870912" "-Wl,/MANIFEST:EMBED" "-Wl,/MANIFESTUAC:level='asInvoker'"
.\examples\hello.exe
```

`build` 默认目标就是 C；显式写出 `--target=c` 可以让脚本意图更清楚。该命令生成 `examples/hello.c` 和 `examples/hello.o`。

## 测试

Python runner 会从 tracked C anchor 临时构建隔离的 `ring.exe`，并按需构建 runtime：

```powershell
python tests/run_tests.py                 # 全部默认门禁
python tests/run_tests.py --suite e2e     # 语言语义 E2E
python tests/run_tests.py --suite golden  # C-native golden
python tests/run_tests.py --suite rc      # post-RC verifier
python tests/run_tests.py --suite self-compile # tracked C 固定点
python tests/run_tests.py --suite structural  # generated-C 结构门禁
python tests/run_tests.py --suite parity      # 静态证据矩阵
```

## 文档

- [语言规范](docs/lang-spec/README.md)：当前已实现的公开语法与语义
- [设计哲学](docs/philosophy.md)：九条公理与仲裁层级
- [编译器与 runtime 设计](docs/design.md)：实现架构和不变量
- [竞品与行业定位](docs/competitive-analysis.md)：有事实截止日期的比较基线
- [开发约定](AGENTS.md)：工具链与仓库入口；当前工作流见[`docs/workflow.md`](docs/workflow.md)
