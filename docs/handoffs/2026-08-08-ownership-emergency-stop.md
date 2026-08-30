# Repository Steward ownership 紧急停止交接（2026-08-08 20:15 +09:00）

> 这是当前真值 handoff，取代
> `docs/handoffs/2026-08-07-ownership-pause.md` 中的旧源码哈希、artifact 与恢复点。
> 旧文件仍可用于理解 #268/#269 的设计背景，但不得用于恢复当前 dirty snapshot。

## 停止原因与用户终点

- Codex desktop 当前 session 已明显卡顿，用户要求立刻终止所有工作、写 handoff 后停止。
- `/root/ownership_truth_resume2` 已被显式 interrupt；停止前状态为 `running`。
- 停止核验时没有命令行指向 ownership worktree 或
  `ring-ownership-bootstrap-2e1ac90a` 的 `ring`、`clang`、`lld`、Python 构建进程。
- 本 session 不再运行编译、测试、merge、commit ownership diff 或性能工作。
- 下一 session 先继续清零 #268/#269 与 #260；critical 真正关闭前不得进入 B-176/B-180。
- 用户此前要求性能优化放到新的独立 session；恢复 critical 时不要顺带实施 cache、并行 runner
  或 compiler hotspot 优化。

## Git 与工作树冻结点

### Main

- Worktree：`C:\Users\Yufeng Ying\Desktop\Ring-lang`
- Branch：`main`
- 停止前 HEAD：`214999cb0369a9264a38de26224f1d00b3bb81d8`
- 状态：停止前 clean，`main...origin/main [ahead 5]`；本 handoff 是随后唯一允许的文档改动。
- `214999cb` 已包含 B-176 test-runner phase-trace continuity；正式 baseline 尚未运行，性能项未完成。

### Ownership transition

- Worktree：`C:\Users\Yufeng Ying\Desktop\Ring-lang\.worktrees\ownership-truth`
- Branch：`codex/ownership-truth`
- HEAD：`102495371cfc97f9e5bd737ed067b399d74fde07`
- 与当前 main 的 merge-base：`0c80598914a7d58210ba02bef7b94f49b6da6f8a`
- 冻结状态：43 个 tracked 文件修改、220 个 untracked 路径；tracked diff 为
  13,671 insertions / 3,841 deletions。
- 核心新文件 `compiler/ownership.ring` 仍 untracked；只看 `git diff --name-only` 会漏掉它。
- 不得 stash、reset、clean、checkout 或从旧失败 worktree 覆盖当前 snapshot。
- `compiler/dist-c/main.c` 未修改，SHA256
  `60FC53609C5E4F48ABC0638BD6E7BBB3E865AA014B8EAEB4332FA9B7CFC01E9E`。
- runtime typeid15 transition bridge 仍必须保留；未完成 integrated fixed point 和 tracked C
  重生前不得删除。

## 当前源码哈希

恢复前先重算并与下表比较。任何不一致都表示 snapshot 在停止后漂移，必须先重新审计状态。

| 文件 | SHA256 |
|---|---|
| `compiler/ownership.ring` | `EC98C2538B1235CC164C6A06BFC0C09565B1E1A74B8E6C9E3240B9047658A8DB` |
| `compiler/hir.ring` | `EBB9557F697B32EDAE079BB863B48BD2DE28217816BF0669D16D1DEF395F6F56` |
| `compiler/perceus.ring` | `E463E2C56CA37F1BECB647329C00B23ED6491353A114C6509AFDB6AA83CE703A` |
| `compiler/scc.ring` | `D88DAB5ACE89E03DD1F8BE4DB911617791A1911CEC33F739956A1519AC99F781` |
| `compiler/codegen_c_expr.ring` | `D082D112BA4A9E2DE72F1051C3529BA55DD578EE1CC96F6A497501CE6374814B` |
| `compiler/codegen_c.ring` | `9FCF7C4859B73E8EA07559272D4F435236B24C281150BDC06D0D0B2835FF8ED7` |
| `compiler/checker.ring` | `F2E0DA9E0232CB6AA48894F8849602570530F6070EBD71C5BD85316B058A3094` |
| `compiler/types.ring` | `DCECAFC9313D849CDC19CA28FCE7492CDE004D104BC39A18299CAECCEE85C4B5` |
| `compiler/exports.ring` | `C2009BCF57A03124C023C5F1A87E320F4D703ED26F10FD90DA498E9288FC7A00` |
| `ring_runtime.cpp` | `B1532B795CA68CCEAB09BDA8DF0536AA0F36132BD82F792D50C5E350B4BECD22` |
| `std/result.ring` | `F0CAFF021D6EF4254ADC3BEFC6A37AF44B600336356CB44BF71808F9FB132CF7` |
| `tests/run_tests.py` | `1C6F7ED5D9B68B9D810A66B03E235CAA2BAC5E8057A3F8C5A76120ABE7C74164` |

## 已闭合的 transition blocker（当前 dirty snapshot）

以下是已经定位并落盘的最小修复，不等于 critical 已关闭：

1. 旧 anchor 的 OR-pattern codegen 兼容边界：14 个共享 binder arm 与
   `(NoBase, _) | (_, NoBase)` tuple-nested arm 已拆分；扩展 inventory 的其余新增 OR arm
   均为 binder-free 外层 enum constructor。
2. ownership term namespace 的 `9e18` 超出 tagged Int 范围，已改为可表示的命名 exclusive
   limit `4e18`，并加入 source/generated-C/limit 边界 oracle。
3. `unify.ring` mutable `Set` 参数被 closure 捕获造成 HIR/C Cell ABI 不一致，已改为显式循环，
   并加入 generated-C oracle。
4. compiler-owned prelude 保留名、Range fresh binder、Set/Map/List/Result/Option 的 pattern
   projection → owned sink transition 已按 partial-move fail-loud 边界收口；Result 使用最小
   per-method Clone bounds，查询方法保持无 bound。
5. primitive Clone dictionary 已补：tagged 值原样返回，heap 值走 `ring_dup`；未触碰
   legacy typeid15 bridge。
6. exact `Option::none` 已在 planner、Perceus 与 verifier 中统一为 immortal singleton，不再
   materialize/Clone/Drop。
7. const getter、prelude extern final-DefId dedupe、Never/Block/If/Match direct-callee identity、
   positional enum ctor export/import、project namespace const alias localization 的 exact DefId/
   descriptor transport已修。
8. 每个 module 重复携带同一份 prelude direct Drop HIR 时，codegen forward registration 只对
   exact fn key/C name/arity/param flags/types/return/effects/evidence ABI/self-owner role幂等；任一
   不一致仍 fail loud，并有正负 source oracle。
9. strict self-host Move 迁移已确认 `andor_lower`、`codegen_c_ctx`、`dict_lower`、
   `effect_analysis` 与 `perceus` 的已知 E0801 inventory 清零；Perceus old-anchor 文件门曾 PASS
   155.473s，且 `callable Move binding edge has no exact Take` inventory 为 0。

## 中断时的精确未完成点

- #268/#269 仍为 doing；ownership diff 未提交、未 review、未 merge。
- 最新 worker 先报告 `scc.ring` 的 43 个 E0801，随后已把扫描推进到
  `codegen_c_expr.ring`（当时 130 个 E0801），最后又修了 HIR `_` wildcard 的 exact metadata。
- interrupt 时正在重跑全 compiler strict diagnostic；该命令未完成，因而当前 snapshot 没有
  canonical 的“strict clean”结论。不要沿用上述 43/130 作为当前精确计数；恢复后必须从
  最新源码重新跑完整 diagnostic。
- 最近一次 gen2 在旧源码 snapshot 上 3.334s fail loud：
  `ring panic: unreachable: callable Move binding edge has no exact Take`。此后源码已经大幅迁移，
  该失败只证明当时 gen2 未形成，不证明当前 blocker 仍相同。
- 当前源码没有 fresh gen1/gen2 fixed point；不得宣称 transition checkpoint。
- latest main 尚未 merge；#260 Json atomic cutover、integrated fixed point、tracked dist-c 重生、
  typeid15 bridge 删除、旧 `ring_json_stringify` runtime 路径删除均未开始。
- ownership/Json/RC/ASan/self-host/full gate 与最终独立 review均未完成。

## Artifact 真值与禁用复用

稳定旧 anchor：

- 路径：`C:\Users\Yufeng Ying\AppData\Local\Temp\ring-ownership-bootstrap-2e1ac90a\ring-old.exe`
- SHA256：`DAACBB6C5587942FA109FE097E9D508BDED2440A4D7F315B1631CCE219FCA0A9`

最后一个可核验的 old-anchor → gen1 记录：

- 目录：`...\gen1-transition-direct-drop-2cbbcac6d439405495f50d26d75bedc2`
- result：同目录 sibling
  `gen1-transition-direct-drop-2cbbcac6d439405495f50d26d75bedc2.old-anchor-build.result.json`
- old-anchor build：exit 0，650.103s。
- 当时生成 C SHA256：
  `574B5364FF3527C0DC52ACAAD6C2D1F1179E36F630F3AFC22275FD7582EC8DFC`。
- 当时 object SHA256：
  `7AB27F87B2C559B364CCD45E2B9F4804289F281C787890BDE5E0C4189C86B8B4`。
- ThinLTO executable：`ring-gen1.exe`，SHA256
  `EDD7AFA3A24C771BF47EBFB4AB5F766A51BFE8DEE01A1D3EA3EFDD2DACC04C92`；其完整 lineage 在
  `thinlto-build.result.json`。
- runtime source SHA256：
  `B1532B795CA68CCEAB09BDA8DF0536AA0F36132BD82F792D50C5E350B4BECD22`。

重要：上述目录后来被 diagnostic build 复用，当前磁盘 `main.c` SHA256 已变为
`2AB77573D21F4A4DE7E22ECC86BA8177AEFFB2E8DBF970E71241013E4AD30C8B`，不再是 executable 的
原始 C 输入。只能相信 result JSON 中固化的 `574B...8DFC`；不得把当前 `main.c` 与
`ring-gen1.exe` 配对声称 lineage。并且当前源码又在此后修改，所以该 gen1 executable 对
当前 snapshot 已 stale，只能作历史诊断证据，不能直接续 gen2。

最近 gen2 失败证据：

- 输出目录：`...\gen2-transition-direct-drop-61d3dda891584afdbd6338792efdf195`（空）。
- result：
  `...\gen2-transition-direct-drop-61d3dda891584afdbd6338792efdf195.parent-build.result.json`。
- parent SHA256：`EDD7...04C92`；exit 1；elapsed 3.334s；无 C/object。

诊断 executable：

- `...\gen1-transition-direct-drop-2cbbcac6d439405495f50d26d75bedc2\ring-gen1-move-edge-diagnostic.exe`
- SHA256：`681011235469209A6BE7A28D7845C3063F2E6C375A531B0C1B8408A2E9B6DC48`
- 仅用于重新取得 strict diagnostic；不得当作 canonical bootstrap generation。

## 下一 session 的最安全恢复顺序

1. 完整读取 `AGENTS.md`、`docs/workflow.md`、`.agents/skills/steward/SKILL.md`、本 handoff，
   再核对 main/ownership HEAD、上述源码哈希与进程状态。
2. 不清理 dirty snapshot，不复用空 gen2 或被覆盖的 gen1 `main.c`。先用 diagnostic executable
   对当前 `compiler/main.ring` 重新取得完整 strict inventory；保留原始 stdout/stderr、命令、
   exit、elapsed。
3. 继续结构化迁移首个失败模块：whole-binding 消费、fresh rebuilt HIR、exact DefId/Take；
   不逐点加 clone/alias，不放宽 partial move，不给 Perceus/verifier增加名字 fallback。
4. compiler/std transition 源保持 old-anchor 可解析的 lv0；旧 anchor 已实证不接受
   `fn f(move x: T)`，Move contract 应由新 solver从函数体推断。确需两阶段语法切换时先给出
   最小反证，不得静默从 stale gen1 起步。
5. 每次 compiler `.ring` 修改后先做 changed-file old-anchor preflight（已测量参考：HIR
   300s、ownership 600s、Perceus约155s），再进行一次全 strict diagnostic。
6. strict clean 后，从 `ring-old.exe` 在全新空目录生成当前源码的 fresh gen1；单次 timeout
   至少2400s，不短轮询。固化命令/exit/time/C+object+runtime+exe hashes，且不得再用该目录
   跑会覆盖 `main.c` 的诊断构建。
7. 用该 gen1 在全新空 gen2 目录生成同一源码；源码若变化，废弃本轮并从 old anchor 重建
   gen1。必要时 gen3，连续 generations 比较字节 fixed point。
8. 重跑 ownership 20项 targeted、golden、5个跨模块 descriptor gates、transition/source/
   generated-C oracles、workflow validation；通过后才形成独立 transition checkpoint commit。
9. 在 clean checkpoint 上 merge 最新 main。必须同时保留 main 的 Json + phase timing 与
   ownership 的 metadata/Take/Perceus/verifier真值；不要因 Git clean merge省略语义 review。
10. 对 integrated source 再做 fresh genA/genB（必要时 genC）fixed point与 ownership/Json
    targeted。只有此后才重生 tracked `compiler/dist-c/main.c`。
11. 证明 integrated tracked C 不再生成 live typeid15 closure env 后，原子删除 runtime bridge
    与对应旧测试路径；同时完成 #260 Json 的旧 `ring_json_stringify` runtime 路径删除。
12. 跑 ownership/Json/C/RC/ASan/self-host/full gate与独立 review，更新 audit状态关闭
    #268/#269/#260。critical 清零后停止；性能工作另开独立 session。

## 恢复时禁止的捷径

- 不把任一旧 gen1 targeted PASS 当作当前 snapshot 或 integrated source 的 PASS。
- 不用 `--update-golden` 吸收 ownership/Json 集成失败。
- 不提交或 merge 未达到 fixed point 的 43 tracked + 220 untracked dirty snapshot。
- 不删除 tracked dist-c、old anchor、typeid15 bridge或旧 Json runtime path来“推动”fixed point。
- 不通过放宽 E0801、把 TypeVar 当 non-owner、Perceus name guessing、全局 Clone 或兼容 shim
  消除诊断。
- 不启动 B-176/B-180、runner cache/并行、prelude cache或其他性能实现，直到全部 critical关闭。
