# `check` feedback measurement harness

This directory is the bounded measurement entry point for B-176. It records
compiler and validation feedback cost without changing default compiler,
runtime, or test-runner behavior. The checked-in manifest is a replay plan; it
does not itself contain a formal baseline.

## Integrity model

`windows_job.py` creates each root process with `CREATE_SUSPENDED`, assigns it
to a fresh kill-on-close Windows Job Object, then resumes its primary thread.
The invocation record distinguishes exact lifetime counters from sampled
memory:

- aggregate user/kernel CPU, total process count, Job I/O, and
  `PeakJobMemoryUsed` come from `QueryInformationJobObject`;
- `PeakJobMemoryUsed` is peak committed memory for the job, **not RSS**;
- root and observed per-process peak working set come from retained process
  handles and `GetProcessMemoryInfo`, including after process exit. The
  per-worker maximum excludes the root and is `null` when no worker existed;
- tree working set is summed every 10 ms. Its sample count, covered duration,
  coverage ratio, observed-process count, and exact Job total are retained.
  `rss_complete=false` makes the tree peak an explicit lower bound when a short
  process was missed, coverage fell below 95%, or sampling produced an error.

Preflight creates, configures, and queries a genuinely fresh Job Object, checks
the kill-on-close flag, and proves that closing it restores the current-process
handle count. Self-tests also assert that one invocation creates exactly one
Job and does not grow the steady-state handle count.

stdout and stderr are never merged. Each is retained with its own path, byte
count, and SHA-256. Runner summaries, declared artifacts, and opt-in JSONL phase
traces are copied into the invocation record rather than inferred later.

Direct successful and diagnostic `check` lanes explicitly request the hidden
compiler option `--phase-timing=<sample path>`. Default compiler invocations do
not call the clock and do not create a timing file. Compiler timing always goes
to that independent JSONL file, never to the human or LLM diagnostic stream.
Every row uses `vorton.compiler-phase-timing.v1`, nanoseconds from a monotonic
clock, exact lane/compiler/source identities, `executed`, `complete`, and
`command_success` flags. The stable phase vocabulary is:

- `input_entry_load`;
- `entry_parse`;
- `project_module_load_parse` (the resolver currently combines module I/O and
  parse, and single-file checks mark it skipped rather than inventing detail);
- `type_effect_check_lower` (checker-owned HIR/dictionary lowering is not yet a
  separate stable boundary);
- `resource_plan_verify` (zero-duration and `executed=false` for ordinary
  checks, measured for `--verify-rc`);
- `command_total`.

The harness requires exact phase order, fields, types, line/path provenance,
and compiler/source/lane/entry identities. Those structural failures are hard
errors even for warm-ups, timeouts, or otherwise excluded attempts. Missing or
known-unreadable traces, incomplete rows, command outcome/execution mismatch,
and timing-accounting failures remain explicit eligibility failures.

Manifest v4 selects trace semantics explicitly. `compiler_phase_timing`,
`runner_phase_timing`, and `bootstrap_phase_timing` are required, mutually
exclusive booleans. A declared trace requires exactly one true mode; an empty
trace list requires all three false. Bootstrap traces continue to use
`vorton.check-benchmark.bootstrap-phase.v1` and are accepted only for the exact
tracked-bootstrap argv, requirements, artifacts, output path, timeout, and
exit recipe. The harness never infers bootstrap semantics from two disabled
modes, and unknown trace schemas fail closed.

The filtered runner lane, all six individual suite lanes, and the full gate
append the runner's exact
`--phase-timing={sample_dir}/runner-phase-timing.jsonl` option. These traces use
`vorton.test-runner-phase.v1` with the exact 12-field contract emitted by
`tests/run_tests.py`: schema/version, contiguous sequence, suite/case, fixed
stage, duration, executed/complete/outcome, exit code, and command category.
Unknown fields (including a hypothetical thirteenth field), schemas, stage or
field combinations, and path/sequence drift are hard errors. Missing or
unreadable traces, incomplete rows, accounting mismatches, and a runner total
that exceeds the enclosing Job wall time make the attempt ineligible.
The runner orchestration residual and total must be one unique final pair;
an earlier duplicate pair or single runner-scoped summary row is a hard error.

Accounting is serial and exact: each suite's child-stage sum plus its
orchestration residual equals `suite_total`; compiler construction and other
runner setup stages plus all suite totals and the final runner residual equal
`runner_total`. A child `nonzero` event is valid evidence for a negative test
case and is not confused with failure of the outer runner. Each lane summary
keeps its own stage/category/suite aggregates, compiler-construction total,
runner total, wall time outside the runner, and suite/runner accounting. Runner
timings are never pooled across lanes.

Compiler-controlled build exits, including a non-zero child `clang`, finalize
the canonical six rows and set `command_success` from the actual command
result. A runtime hard-fatal I/O panic (for example failure inside `write_file`)
cannot return through compiler-controlled finalization; its trace is therefore
missing or incomplete and the attempt is invalid, never successful evidence.

`tiny_hello_check_no_phase` is an otherwise identical 21-sample, independently
scheduled control lane. The combined report exposes it as
`unpaired_descriptive_control` and compares cold/warm wall median, MAD, and
empirical p95 against `tiny_hello_check`, including absolute deltas and ratios.
Those values are descriptive only: the two lanes are not interleaved or matched
by attempt, so their deltas and ratios are not an instrumentation-overhead
estimate.

### Disabled-default-path budget evidence

The formerly reported base/snapshot 5+41 AB/BA result is **superseded and is
not evidence**. Its candidate still allocated disabled timing state and its
archived source/runtime provenance was not symmetric enough for the claimed
comparison. No performance pass is inferred from those numbers.

Replacement evidence must be produced only by the checked-in disabled-path
gate and accepted by its deterministic verifier. The retained JSON/JSONL must
bind both archive commits and source hashes, raw and COFF-timestamp-normalized
binary hashes, exact tool executables/versions/flags, machine and power state,
the five discarded warm-ups, all 41 alternating pair orders and wall-clock
durations, and every invocation's exit/stdout/stderr contract. The verifier
recomputes all statistics and the preset thresholds from raw rows; a stored
summary or stored PASS value is never trusted.

Run the bounded gate only from a clean candidate commit, using full lowercase
commit IDs and an unused ignored results directory:

```powershell
python bench/check/disabled_path_gate.py run `
  --base-ref <40-hex-base-commit> `
  --candidate-ref <40-hex-current-HEAD> `
  --output bench/check/results/disabled-path-gate
python bench/check/disabled_path_gate.py verify `
  --evidence bench/check/results/disabled-path-gate/evidence.json
```

`run` archives both commits, extracts and builds them sequentially through the
same absolute source/build paths, and removes every archive, object, and binary
only after the checked-in verifier accepts the retained evidence. A failure
keeps the scoped stage for diagnosis. A successful bundle contains only its
JSON plus small command/stdout/stderr sidecars; source identity is rechecked
against `git show <commit>:<path>`, so a missing commit or object fails closed.
The archive command pins `core.autocrlf=false`, making archived text bytes equal
to the referenced Git blobs even when the Windows checkout enables AutoCRLF.
Before either binary is sampled, the gate also proves that the exact 11
`std/*.vorton` files consumed by `checker.vorton` are byte-identical across both
archives and Git objects. It writes those verified candidate bytes to the
neutral `stage/std` directory; both binaries run from the same sibling
`stage/cwd`, so prelude discovery cannot depend on either subject source tree.

## Sample policy

- `direct_short`: retain one excluded warm-up, then require 21 valid samples.
- `adaptive`: the first valid invocation selects 5 samples when it is under
  300 seconds, otherwise 3.
- `full_gate`: always require 3 valid samples.
- A lane gets at most `target + 2` measured attempts. Failing to obtain the
target is a failed run, never a silently reduced sample set.
- All raw attempts stay in `samples.jsonl`, including warm-up and invalid
  attempts. Summaries report median, median absolute deviation, and range;
  empirical p95 is emitted only for exactly 21 valid samples.

An invocation with incomplete RSS coverage or any sampling error is retained as
an invalid lower-bound row; it never enters the formal aggregate. Lane summaries
count complete/incomplete samples, unavailable worker peaks, measurement errors,
runtime-isolation errors, and separately summarize incomplete tree-RSS lower
bounds.

Cold and warm are separate lane IDs. Every invocation is labelled only with:

```json
{
  "thinlto_cache": "cold|warm",
  "output": "fresh",
  "os_file_cache": "uncontrolled"
}
```

Cold lanes point `TEMP`/`TMP` at a fresh per-sample directory, so the runner's
hard-coded `vorton-lang-thinlto-cache` is empty for every invocation. That
generated cache is removed after counters and artifacts are collected. The
harness itself owns the bounded warm seed recipe: from a clean worktree it
builds the tracked anchor/runtime/link once with `bootstrap.py` into an empty
cache and writes a strict receipt beside it. The receipt binds source files,
tool executables (including the exact `lld-link`), flags, exact seed
argv/outcome, the built compiler and intermediate outputs, and a per-file
canonical cache inventory. The bootstrap output remains beside the cache as
`vorton-lang-b176-warm-seed-output`; formal lanes use only its receipt-proven
`vorton.exe`. Formal cold and warm batches verify the same receipt, build output,
and current seed bytes. Warm batches copy the seed cache into their run
directory and mutate only that isolated working copy, so one batch cannot warm
a later batch. Keep the seed cache, receipt, and bootstrap output together until
all dependent formal batches have been combined, then remove the three as one
seed lifecycle. The retained receipt is part of the combine fingerprint. OS
file cache is deliberately not flushed or claimed as controlled.

The Python runner also has a separate ignored root artifact,
`vorton_runtime.o`. Lanes that can consume it (`filtered_e2e_bool_ops`, e2e,
golden, and the full gate) isolate it for every invocation and restore any
pre-existing object afterward. Cold samples start with no root object and therefore measure
its O2 build each time. Warm samples receive an unmeasured, freshly prepared
object built with the runner's exact clang++ path and
`-std=c++17 -O2 -D_CRT_SECURE_NO_WARNINGS`; its source/object hashes, flags,
pre/post state, and restoration result are recorded. A stale ignored object can
therefore neither silently turn a cold sample warm nor contaminate another lane.
The original is atomically renamed to a same-directory ignored backup before
any replacement; warm installation is copied to a sibling staging path,
hash-checked, then atomically renamed into place. Restoration is attempted
before cleanup. If restoration itself fails, the backup is deliberately kept
and its path/state is recorded instead of deleting the only original copy.

## Commands

List the expanded cold/warm lanes and run static preflight:

```powershell
python bench/check/run.py --list
python bench/check/run.py --prepare-warm-cache `
  --thinlto-cache "$env:TEMP\vorton-lang-thinlto-cache"
python bench/check/run.py --preflight `
  --case suite_parity_cold `
  --thinlto-cache "$env:TEMP\vorton-lang-thinlto-cache" `
  --confirm-cache-state cold
```

Run one direct lane from a clean worktree. The compiler is selected exclusively
from the validated bootstrap receipt/output prepared above:

```powershell
python bench/check/run.py `
  --case tiny_hello_check_warm `
  --thinlto-cache "$env:TEMP\vorton-lang-thinlto-cache" `
  --confirm-cache-state warm `
  --output C:\path\to\fresh-results
```

Formal runs require a clean tracked worktree. A one-invocation harness probe is
available while developing the harness and is explicitly not baseline evidence:

```powershell
python bench/check/run.py --probe --output "$env:TEMP\vorton-check-probe"
```

Run the short self-tests:

```powershell
python -m unittest discover -s bench/check -p "test_*.py" -v
```

Formal cold/warm lanes may be run in separate fresh result directories. Combine
only a complete set of non-overlapping batches into one auditable baseline:

```powershell
python bench/check/combine.py `
  --run-dir C:\path\to\batch-1 `
  --run-dir C:\path\to\batch-2 `
  --output C:\path\to\fresh-combined
```

The strict combiner revalidates every raw attempt and recomputes eligibility and
lane summaries. Trace wrappers preserve their resolved manifest path and source
line; paths must remain inside the recorded sample directory and lines must be
unique and contiguous. Stored inclusion and exclusion reasons must exactly
match the recomputed policy, measurement, runtime, artifact, runner-summary,
and phase-trace result. The combiner
requires identical source, manifest/result schema, tracked bootstrap/runtime,
toolchain, flags, and stable machine/power identity; rejects dirty/incomplete
runs, duplicate lanes/samples and identity drift; and requires the full manifest
cold/warm coverage matrix. It writes `combined-samples.jsonl` and
`combined-summary.json` plus the shared manifest/schema snapshots.

Runner-runtime mode, source/flag identity, transaction paths, original/prepared
state, and clean postconditions are reconstructed from the manifest,
environment, and sample identity. The `errors` strings themselves originate in
the in-process isolation transaction and have no independent sidecar log; the
combiner uses them when recomputing eligibility and checks every reconstructible
field, but cannot independently recreate historical OS error text after the
transaction has ended. This is an explicit retained-record trust boundary.

## Output contract

Every fresh result directory contains:

- `manifest.snapshot.json` and `result.schema.json` — exact replay contract;
- `environment.json` — commit and dirty state, manifest hash, tracked
  `dist-c`/runtime hashes, Python/clang/clang++ paths, versions and executable
  hashes, flags, OS, CPU, total memory, logical cores, power status/plan, and
  exact warm-seed receipt/cache inventory, plus runner-runtime preparation
  state and hashes;
- `warm-cache-seed-receipt.json` — retained strict seed identity used by both
  cold and warm formal batches;
- `samples.jsonl` — one schema-validated row per invocation;
- `samples/<case>/<sample>/stdout.txt` and `stderr.txt` plus declared artifacts;
- `summary.json` — statistics derived only from included rows and a hard
  completeness result.

`manifest.json` includes tiny/large/module/diagnostic/RC direct checks,
`compiler/main.vorton`, hello build, the uniquely filtered `filtered_e2e_bool_ops`
case, each current suite, the full
gate, and a fresh tracked-bootstrap build. `bootstrap.py` mirrors the production
O3+ThinLTO build into the sample directory and emits compile/runtime/link phase
wall times. Compiler-internal phase traces are requested only by the direct
`check` lanes described above; runner traces are requested only by the eight
runner lanes listed above.

The checked-in runner-summary contract deliberately remains at the pre-
ownership-integration snapshot of 1556 full-gate cases. After the ownership
work lands, all suite counts and case-identity digests must be replayed and the
manifest byte pin refreshed before collecting the formal B-176 baseline. The
current runner-trace wiring does not claim that replay has happened.

The harness is Windows-only because the measurement contract is specifically a
Windows Job Object contract. The implementation uses Python's standard library
only; its small JSON-schema validator intentionally supports only the keywords
used by `result.schema.json` and fails closed on unexpected result fields.
