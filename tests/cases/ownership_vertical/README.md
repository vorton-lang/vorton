# 0.1 ownership vertical fixtures

本目录是 `#268/#269` 统一 fast 真实矩阵的 source corpus。每个正例由 Ring
运行时断言和可观察 stdout 裁决；每个负例由真实 compiler diagnostic 裁决。
这里没有 Python source-string scan，也没有 post-0.1 占位 surface。

`manifest.json` 是 fixture 清单与终态期望的真值。
`single/` 保存单文件入口，`modules/` 只保存 project 入口及其 support module；
support module 不应被 runner 当成独立 native case。

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

合法 Ring source 中的多态 effect tail 必须归属并 generalize 在 callable owner；
普通 source 无法制造 raw/unowned Core state。因此 D3 是 source-level positive，
raw/unowned negative 由 manifest 中的 D6 internal Ring mutation canary 覆盖：
runner 以 D3 为合法输入、追加 `--rc-mutate=core-unowned-effect-tail`，并要求
nonzero 与逐字节 panic
`ring panic: Core assembly: unowned raw effect tail crossed Core`。
禁止为了凑 source 负例改用 Python 字符串 oracle。

## 当前固定边界

历史开发二进制只保留为外部证据，不是本矩阵候选，也不能提供当前
PASS。当前累计源码已通过 focused source checks；真实行为必须等待 root 从固定
authority checkpoint 构建新的 source-built aggregate compiler，并记录 compiler、
std、runtime 与 toolchain 身份后一次执行本矩阵。候选产生前所有行为项均为
未执行，不使用模糊等待状态、历史绿色或旧内嵌 std 豁免终态期望。

B1 已收紧为 check-negative TypeResource matrix：direct、wrapper、Option、List、
Map、Set、tuple 与 recursive 八个资源形态都必须各自产生 E0801，而
`Wrapper<Int>` 的 `plain` 必须不被误报；旧 native stdout 观测已退役，
不再是 fixture 或 PASS 证据。D1 现以两个同签名 handled effect
验证 evidence 顺序，终态 stdout 为 `D_HANDLED_HOF_OK:1235`；D3 以同一个
open HOF formal 分别实例化 pure 与 handled row，终态 stdout 为
`D_GENERALIZED_TAIL_OK:6/12`。D1、D3 在 updated aggregate compiler 上尚未
运行，不能沿用旧 fixture 的 native 绿色。详细期望与 furthest phase 见
manifest。B3 还逐字校验实际 reuse token 的行列，禁止退回 owner declaration span。

## Runner 当前契约

`tests/ownership_vertical_runner.py` 已由 `tests/run_tests.py` 的
`ownership-vertical` suite 接入；它以 manifest 枚举 case，不递归 glob
support module。

1. `expected.phase=native` 执行 `check -> build --target=c -> link/run`，要求
   exit 0 且 stdout literal match；`expected.phase=check` 要求 nonzero、命中
   全部 diagnostic code/text、拒绝 forbidden diagnostic，同时拒绝 internal
   compiler error。
2. 对同一 `parity_group` 比较 literal stdout；F1/F2 必须走同一个 semantic
   compiler entry，只允许输入包装不同。
3. D6 callback 是 acceptance run 的必选项且没有跳过开关：
   必须只接受 manifest 固定的 exact Ring panic，缺 callback、exit 0 或任一
   stdout/stderr 漂移都 FAIL。
4. 用唯一固定 aggregate compiler + matching std/runtime 执行完整矩阵；不得用
   45d 内嵌旧 std 的结果、历史 PASS 或跳过状态豁免终态期望。
