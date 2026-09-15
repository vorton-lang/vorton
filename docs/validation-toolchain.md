# 外部验证工具链

本仓库固定使用 Rust `1.98.1`、Verus `0.2026.09.13.671956e`、Proptest `1.11.0` 与 Kani `0.67.0`。Verus 官方发行版也使用 Rust `1.98.1`；Kani 则隔离使用自身固定的 `nightly-2025-11-21`，两者不是同一份构建证明。

这些入口只自检工具安装、真实执行、正反裁决和报告链路。它们不证明 Vorton compiler 正确，不添加 Checker 语义或语言验收规则，也不改变五项 canonical gate。

## Windows 与 Ubuntu 所需入口

安装 Python 3.10+ 与 rustup 后，在 fresh checkout 根目录运行：

```text
python tools/validation/run.py required --install
```

这是 Windows 本地与 Ubuntu CI 共用的入口。它会核对项目 `rustc`／`cargo`、下载并校验固定 Verus 官方发行包，然后依次执行：

- Verus 无 `assume`／`admit` 等逃生口的正证明，并要求非零 verified 数；
- Verus 语法正确但证明失败的反例，并只接受预期 postcondition failure；
- Proptest 的固定种子生成、正例、反例缩减和缩减后输入重放。

下载、解压、Cargo 构建和重放记录都位于已忽略的 `target/`。Verus 下载包按 GitHub release 提供的大小和 SHA-256 校验；存在不完整或不匹配的缓存时入口会报出具体路径并停止，不会静默覆盖。若已有 Verus，可把 `VORTON_VERUS` 设为 executable 或其所在目录；版本和内置 Rust toolchain 必须完全匹配。

只运行一项自检：

```text
python tools/validation/run.py verus --install
python tools/validation/run.py proptest
```

后续 Verus 目标可通过同一版本门运行，并且仍要求成功且验证项非零：

```text
python tools/validation/run.py verus --install --file path/to/proof.rs
```

Proptest 是 `vorton-compiler` 的固定 dev-dependency，后续 property test 直接由现有 `cargo test --workspace --locked` 入口运行；它不进入 compiler 的生产依赖。自检产生的实际缩减输入保存在 `target/validation/proptest-replay.txt`，随即由第二次 Proptest 执行重放，不把临时数据提交到 Git。

输出中的 `POSITIVE_OK`、`EXPECTED_COUNTEREXAMPLE` 和 `REPLAYED_COUNTEREXAMPLE` 是不同结果。工具缺失、版本不符、命令异常、零项证明、Proptest abort、结果无法解析或未完成都会以 `INFRASTRUCTURE_ERROR` 非零退出，不能冒充预期反例。

## 显式 Kani 补充入口

Kani 只支持这里的 x86_64 Linux／WSL 显式自检，不进入默认 CI job，也不默认检查整个 compiler：

```text
python tools/validation/run.py kani --install
```

入口把 `kani-verifier` 与 `KANI_HOME` 隔离到 `target/validation-tools/`，核对 Kani `0.67.0` release bundle 实际记录的 `nightly-2025-11-21`，再各运行一次小型正例和反例。每次只选择一个 harness、保持单 job、保留 Kani 默认 safety checks，并固定 `u8 <= 2` 输入域和 unwind `4`；不会扩大规模、提高预算或自动重试。正例必须完整结束，反例必须是命名 assertion 的真实 counterexample；unwinding failure、undetermined、工具异常或资源失败都按基础设施错误处理。

若已有隔离 Kani 安装，可同时设置 `VORTON_KANI` 和 `VORTON_KANI_HOME`；入口仍会核对 executable 版本及 release bundle 的 nightly。后续补充检查应直接使用这份已核对的 Kani，在具体工作中显式审阅 harness、输入域与 unwind；本自检的边界不是 compiler 检查的通用预算。
