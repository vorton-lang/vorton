# Repository Steward ownership 暂停恢复点（2026-08-07 20:06 +09:00）

> 用户要求在当前节点暂停并记录状态。本文件覆盖
> `docs/handoffs/2026-08-07-steward-restart.md` 中 ownership 主线的旧快照；旧文件其余
> B176/Json 历史仍可作为背景证据。恢复时先完整读取 `AGENTS.md`、
> `docs/workflow.md` 与 `.agents/skills/steward/SKILL.md`，再按本文只读核验现场。

## 暂停边界

- 2026-08-07 20:06 +09:00 按用户要求主动暂停；此后没有继续修改 ownership 源码。
- 已停止或结束全部子任务：`ownership_truth` interrupted，`ownership_regressions` 与
  `shape_cfg_review` completed；`drop_identity_explore` 因平台误判而 errored，未重试。
- 已核对无 `ring.exe`、`clang.exe`、`clang++.exe` 或 `lld-link.exe` 残留进程。
- 不提交、不 merge 当前 ownership 大型过渡 diff；它尚未生成 gen1，不能伪装成 clean
  checkpoint。必须保留 worktree 与临时 bootstrap 证据目录。

## 用户优先级（继续有效）

1. 先清零 critical correctness；当前主线是 audit #268/#269 ownership。
2. critical 清零后立即完成 B176 → B180，优先降低 `check`、RC/self-verify 与完整门耗时。
3. 项目尚未发布；允许采用最简单的原子 breaking change，不为旧行为增加兼容工作量。
4. performance 不得靠删测试、扩大 skip、自动重试失败或只跑快子集换取。

## Main 状态

- 工作区：`C:\Users\Yufeng Ying\Desktop\Ring-lang`
- Branch：`main`
- HEAD：`47c7c577d565e591d67f0faf562815a458f3c2c1`
- `origin/main`：`04f18edcbdf4806074475cd7bfc6b218dda31116`
- 写本文件前 main clean，`main...origin/main [ahead 2]`。
- 当前两个本地提交：
  - `3ca84d34 docs: record Json and timing continuity milestone`
  - `47c7c577 docs: define owner-bearing closure capture boundary`

`47c7c577` 已落档最终 closure/handler ownership 边界：普通 closure 对 may-own 捕获 fail
loud；tail-resumptive handler 的 may-own/TypeVar exact outer capture 因 evidence 可随 effectful
callable 逃逸而 fail loud；abort `fail.raise` handler 保持 inline；物理 closure env 使用显式 RC
mask。

## Ownership worktree 精确状态

- Worktree：`C:\Users\Yufeng Ying\Desktop\Ring-lang\.worktrees\ownership-truth`
- Branch：`codex/ownership-truth`
- HEAD：`102495371cfc97f9e5bd737ed067b399d74fde07`
- 与 main 的 merge-base：`0c80598914a7d58210ba02bef7b94f49b6da6f8a`
- 当前是有意保留的 dirty transition snapshot：31 个 tracked modified status entry、210 个
  untracked status entry；tracked diff 为 7,052 insertions / 1,893 deletions。
- `compiler/ownership.ring` 是 untracked 核心源文件，任何只看 `git diff --name-only` 的恢复
  检查都会漏掉它。
- `git diff --check` 通过，仅有现有 LF→CRLF 提示。
- tracked `compiler/dist-c/main.c` 未修改；它仍含旧 typeid 15 closure env 分配，不能作为新
  snapshot 的生成结果。

暂停时关键文件 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| `compiler/hir.ring` | `24678531B27F2718FA1B4540F35CEFB798F4FF1BE4FB942A712EBE8BF42DC9DB` |
| `compiler/ownership.ring` | `DA571CE6F6135B5B4CE929B5FB02B1216395860B141F07893A52A92643167DB6` |
| `compiler/infer.ring` | `6AE4C8EFE6ABE343E201729464C8EB69E9C87E6AC4B15F3E6DAE424ACF9CA35B` |
| `compiler/perceus.ring` | `A75ECE6E965CB6AA55FF9F98359F06485889725479EFDDED237B742108CA4DE9` |
| `compiler/verify_rc.ring` | `FA63498B75DD9C5266B5D60131EE4AD41F825D0DCDB5F4F21971B5D82D843C16` |
| `compiler/codegen_c_expr.ring` | `C73D71BC9632B41C14E00A3C40BA433EE7A250D11FF73873A56087F1A0F05D7B` |
| `ring_runtime.cpp` | `2DBFA196EAE6C9C21521B1DE84C6FEA632C950E6A9B98F13EA3857CCECAB530C` |
| `tests/run_tests.py` | `BF623D043D81A191B9007613DE75F09DDEDAF59F27A9AA9D522F3CDEDC508DBC` |

恢复时先重算这些哈希；若不一致，先确定修改来源，不要覆盖或回滚未知改动。

## 已冻结的 transition truth

独立静态复审结论是 **PASS（仅 transition snapshot）**，覆盖：

1. tail-resumptive handler 对 exact outer may-own/TypeVar 捕获报 E0801；abort fail handler
   inline。
2. evidence/dictionary env slot 以 mask 1 保存并 `ring_dup`；source capture 走物理 RC eligibility。
3. 四个 closure env 构造点共享 masked layout。
4. old typeid 15 → new typeid 22 bridge 只在 bootstrap 过渡期成立。
5. dead-tail planner/capture/ANF/RC/verifier/emitter 共用可达性语义。
6. 当前 source/backend 双 capture traversal 没有形成静态 blocker。

新物理 closure env（typeid 22）布局为：

```text
{ int64 count; void* captures[count]; intptr_t rc_mask[count] }
```

- mask 1 当且仅当 env 已通过 `ring_dup` 获得引用；drop 也只处理 mask 1。
- `Ptr`、direct extern、contains-extern 为 mask 0；`Str`、`Int` 等物理 RC eligible 值为
  mask 1；evidence/dictionary slot 为 mask 1。
- runtime 中 old typeid 15 只为 tracked 旧编译器 bootstrap 暂留；fixed point 后必须删除，
  不得成为兼容 ABI。
- HIR `expr_has_reachable_value` / `stmt_reaches_next` 是 dead reachability 单一真值；ownership
  planner 在终止语句后物理裁剪 dead suffix/tail，solver、exact capture、callable return
  provenance、backend capture、C emitter、Perceus 与 verifier 消费同一语义。

## 已冻结的测试与 oracle

- regression worker 已交付测试/runner snapshot；Python compile、JSON、静态 integrity 与
  diff-check 均通过。
- 旧编译器运行 structural oracle 恰好得到 23 个断言失败，证明 oracle 非空：15 个缺失
  masked env、4 个 RC-ineligible 值被错误 dup、2 个 evidence dup 缺失、1 个 runtime typeid
  应为 22、1 个 fixture 输出仍含旧 typeid 15（其中 18 个 allocation）。这些是旧编译器的
  预期反证，不是新 snapshot 的通过结果。
- 重点新增正例：
  - `ownership_closure_env_physical_mask`
  - `ownership_effectful_named_fn_evidence_local`
  - `ownership_dead_closure_handler_capture`
- 已增加 tail handler Resource/generic/evidence escape 错误用例及 structural
  `closure_env_rc_mask.ring`。
- 新 compiler 尚未生成，因此没有运行 targeted C/RC/ASan，也没有运行完整门。

## Bootstrap 实测与当前唯一前沿

保留现场：

`C:\Users\Yufeng Ying\AppData\Local\Temp\ring-ownership-bootstrap-2e1ac90a`

- `ring-old.exe`：5,481,984 B，SHA-256
  `DAACBB6C5587942FA109FE097E9D508BDED2440A4D7F315B1631CCE219FCA0A9`。
- `gen1`、`gen2`、`gen3` 当前均为空；**尚未生成 gen1**。
- `diag-anchor/ring-diag-o3.exe` 是只修改临时 tracked-C 副本、在旧 codegen panic 前打印
  symbol 的诊断 anchor；SHA-256
  `48C24B31E0F0FA7B071A28C43E2F06911A169840CC9F69E1FD3B056186CEF655`。
- `diag-gen1`、`hir-probe` 与日志均为诊断证据；不要把它们复制进仓库，也不要在恢复前
  删除整个临时目录。

实际尝试：

1. old anchor full build #1：420.6s，发现 `compiler/infer.ring` 漏 import
   `PARAM_OWNERSHIP_MOVE`；已修。
2. full build #2：608.8s，发现 `compiler/ownership.ring` 的 table/state mutability 错误；已
   修。旧 Ring 不接受 `some(mut state)`，最终采用 `some(found_state)` 后在分支内建立 mutable
   local。
3. targeted old-anchor `check compiler/ownership.ring`：修正后 241.3s 通过，仅 warnings。
4. full build #3：623.1s，source check 已过，但旧 C codegen 在
   `ring_hir$$_expr_has_reachable_value` 因共享 OR-pattern binder 报 undefined `fields`；已把
   `StructLit | NamedVariantConstruct` 与 `ListLit | TupleLit` 分开。
5. old-anchor `check compiler/hir.ring`：77.2s 通过。
6. diagnostic single-module C probe：97.7s，当前精确失败为：

```text
ring_hir$$_stmt_reaches_next
ring panic: C codegen: undefined variable 'init' (resolved: 'init')
```

暂停发生在修这个 bootstrap-only shared-binder 问题之前；当前 `hir.ring` 哈希证明没有半截
写入。不要重复已经完成的前三类修复。

## 恢复后的精确执行顺序

1. 完整读取仓库/steward 指令与本文件，核对 main、worktree、进程、agent 及上述哈希。
2. 只改 `compiler/hir.ring`：把 `stmt_reaches_next` 中
   `HStmt::Let | HStmt::Var | HStmt::ExprStmt | HStmt::LetDestructure` 的共享 `init` binder
   拆为四个独立 arm，均调用 `expr_has_reachable_value(init)`。
3. 同一小步主动检查本轮新增的 `collect_exact_free_binding_expr/stmt` 等 HIR helper：只拆会
   读取 binder 的 OR-pattern arm；binder-free leaves 不做机械扩张。
4. 运行旧 `ring-old.exe check compiler/hir.ring`。
5. 用 `diag-anchor/ring-diag-o3.exe build compiler/hir.ring --target=c --no-c-lines` 对一个
   **fresh output dir** 做单模块 C probe；现有 `hir-probe` 不复用。若仍报旧 codegen binder
   问题，保持一次一个最小修复并重复 4–5。
6. 单模块 C generation 通过后，才对 fresh/empty `gen1` 重跑 old-anchor full build。
7. 获得 gen1 后继续 gen2、字节 fixed point、targeted tests；随后删除 typeid 15 bridge，
   重生 tracked `compiler/dist-c/main.c`，再跑完整门与独立 final review。
8. ownership critical 真正关闭后，按既定排序立即回到 B176 → B180 工具链性能主线。

## 明确未完成

- #268/#269 尚未关闭，ownership diff 未提交、未 merge。
- 没有 gen1/gen2，没有 compiler fixed point。
- typeid 15 bootstrap bridge 尚未删除，tracked dist-c 尚未重生。
- targeted C/RC/ASan 与完整门均未运行。
- consuming match 尚未开始。
- 静态 reviewer 的 transition PASS 不得表述为 merge approval 或 critical 已修复。
