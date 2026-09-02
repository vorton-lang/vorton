# 0.1 ownership vertical fixtures

本目录是 `#268/#269` 统一 fast 真实矩阵的 source corpus。每个正例由 Vorton
运行时断言和可观察 stdout 裁决；每个负例由真实 compiler diagnostic 裁决。
这里没有 Python source-string scan，也没有 post-0.1 占位 surface。

`manifest.json` 是 fixture 清单与终态期望的真值。
`single/` 保存单文件入口，`modules/` 只保存 project 入口及其 support module；
support module 不是独立 native case。

## 覆盖面

- A：List/Option/Map/Set deep clone、嵌套 clone、泛型 `Clone` bound、缺 bound
  与 `Drop + Clone` 冲突、clone 后原容器独立。
- B：direct/nominal/container/tuple/recursive/generic TypeResource，
  `Wrapper<Int>` 与 `Ptr<Resource>` 负控，以及 consume 后 reuse 的 E0801。
- C：named/lambda/factory/struct fields/tuple/enum callable carrier 与
  no-global-same-signature widening。
- D：closed/polymorphic effect HOF、pure/console exact identity、handled
  evidence、system extern function value，以及 custom extern/default-op 负例。
- E：十个 compiler extern bridge 的 typed manifest、10/10 runtime inventory，
  以及 user same-spelling isolation。
- F：同一所有权语义的 single/project literal native parity。

合法 Vorton source 中的多态 effect tail 必须归属并 generalize 在 callable owner；
普通 source 无法制造 raw/unowned Core state。因此 D3 是 source-level positive，
raw/unowned negative 由 manifest 中的 D6 internal Vorton mutation canary 覆盖：
D6 以 D3 为合法输入、追加 `--rc-mutate=core-unowned-effect-tail`，并要求
nonzero 与逐字节 panic
`vorton panic: Core assembly: unowned raw effect tail crossed Core`。
禁止为了凑 source 负例改用 Python 字符串 oracle。

## Manifest 语义

- `expected.phase=native` 的正例要求可观察 stdout 与 literal 完全一致；
  `expected.phase=check` 的负例要求命中全部 diagnostic code/text，并拒绝
  `diagnostic_forbidden` 与 internal compiler error。
- 同一 `parity_group` 的入口必须产生相同 literal stdout；single/project 只允许
  输入包装不同，不允许改变 semantic compiler entry。
- D6 internal canary 只接受 manifest 固定的 exact Vorton panic；exit 0 或任一
  stdout/stderr 漂移都不满足期望。

这些文件只保存迁移后的 compiler 可复用的语义输入与期望，不指定当前执行器、
candidate 或 PASS。由未来实现 Issue 建立的真实 compiler gate 决定如何消费它们。
