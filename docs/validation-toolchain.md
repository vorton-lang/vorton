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

## Vorton 语义护栏

普通工作单元在 exact candidate 的 clean checkout 运行：

```text
python tools/semantic_guard/self_test.py --install
```

该入口直接验证 compiler 实际调用的 formal 等价类核心，要求 `formal_merge_allowed`、`merge_label` 与 `merge_classes` 三个指定目标出现在 Verus 报告中且 verified 总数非零；同时运行固定种子的生产核心 property、真实 `check_project` 正反性质，以及破坏核心、漏登记独立域、断开接线三个预期失败的隔离 mutant。Verus target 与实际核心是同一份 Rust 函数体；`assume`、`admit`、axiom、external body 等未验证逃生口会在执行证明前被拒绝。mutant 副本与构建输出使用新的 `target/semantic-guard/runs/` 子目录并保留，不改正式 checkout。CI 以 `--expected-candidate <40-hex-sha>` 同时核对实际 checkout HEAD；PR 使用事件的 `pull_request.head.sha`，不采用默认 synthetic merge checkout。

护栏自身或被证明核心变化时，额外运行历史错误对照：

```text
python tools/semantic_guard/history.py
```

入口从本仓库 Git objects 导出五个固定 historical commits，在各 revision 自带的 Rust toolchain 与原 `Cargo.lock` 中只登记本地 probe package，随后以 `--locked` 构建真实 public `check_project` probe；registry dependency 集合不变。case manifest 固定五类语义输入、原始 revision、期望历史误判、正确候选裁决及 source／contract origin。历史成功构建并重现指定误判才算完成；接受、指定语义拒绝、decode／前端错误、产品崩溃和基础设施错误分别记录。最终输入不读取个人临时目录。

声称实现受保护 #65 范围的候选，由独立审定的 clean guard baseline checkout 运行：

```text
python tools/semantic_guard/candidate.py --repository <candidate-repository> --candidate <40-hex-sha>
```

runner 与 manifest 始终来自 baseline，archive 和 compiler 来自被测 SHA；输出同时绑定 baseline 与 candidate。当前 main 尚不支持的 Trait／Effect 等场景在普通 self-test 中明确不适用；candidate acceptance 没有不适用或自行缩减范围的通道。护栏 Git revision 是执行证据中的 baseline 身份，不替代语言规范或 Issue 原生正文修订。

## 显式 Kani 补充入口

Kani 只支持这里的 x86_64 Linux／WSL 显式自检，不进入默认 CI job，也不默认检查整个 compiler：

```text
python tools/validation/run.py kani --install
```

入口把 `kani-verifier` 与 `KANI_HOME` 隔离到 `target/validation-tools/`，核对 Kani `0.67.0` release bundle 实际记录的 `nightly-2025-11-21`，再各运行一次小型正例和反例。每次只选择一个 harness、保持单 job、保留 Kani 默认 safety checks，并固定 `u8 <= 2` 输入域和 unwind `4`；不会扩大规模、提高预算或自动重试。正例必须完整结束，反例必须是命名 assertion 的真实 counterexample；unwinding failure、undetermined、工具异常或资源失败都按基础设施错误处理。

若已有隔离 Kani 安装，可同时设置 `VORTON_KANI` 和 `VORTON_KANI_HOME`；入口仍会核对 executable 版本及 release bundle 的 nightly。后续补充检查应直接使用这份已核对的 Kani，在具体工作中显式审阅 harness、输入域与 unwind；本自检的边界不是 compiler 检查的通用预算。

泛型等价类核心的显式补充目标复用同一生产函数，命令为：

```text
python tools/validation/run.py kani --install --file tools/semantic_guard/formal_merge_kani.rs --harness semantic_guard_kani_merge_small_domain
```

该 harness 只取三个 formal、`u8 <= 2` 的索引输入、一个已建立合并和一条 caller 独立关系，在 unwind `4` 与默认 safety checks 下检查裁决、合并范围、拒绝原子性和独立关系保持。它不证明登记 caller 完备，也不替代无界 Verus 证明或真实 `check_project` property。
