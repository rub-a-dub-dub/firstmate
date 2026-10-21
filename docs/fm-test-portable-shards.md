# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-latest`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

Both hint tables were refreshed on 2026-09-30 from five Ubuntu CI runs: [36583881812](https://github.com/kunchenguid/firstmate/actions/runs/36583881812), [36658498535](https://github.com/kunchenguid/firstmate/actions/runs/36658498535), [36663947738](https://github.com/kunchenguid/firstmate/actions/runs/36663947738), [36664663190](https://github.com/kunchenguid/firstmate/actions/runs/36664663190), and [36669175457](https://github.com/kunchenguid/firstmate/actions/runs/36669175457).
Use the slowest successful `duration_ms` per script across their uploaded portable timing artifacts and completed `FM_TEST_END` log markers, with the two version/platform exceptions below.
All artifact records were cross-checked against the corresponding job's markers.
This covers all 24 parallel members and the 201 serial members the lane held at that refresh; `--check-coverage` names any serial member added since under `serial_unhinted=`, and an existing live-capability skip is a portable-runner measurement, not a timing claim for the unavailable live integration.
The parallel table still rests on that baseline, while the serial table was refreshed again on 2026-10-21 from the fork runs recorded in [Fork refresh, 2026-10-21](#fork-refresh-2026-10-21).
Observed maxima provide conservative packing weights, not an upper bound on future durations.

Two serial-5 jobs were cancelled at their 30-minute cap and uploaded no artifact.
Their completed log markers supplement the complete runs, but a cancelled job's wall time is only a lower bound and its unfinished or never-started scripts have no completed sample.
A failed script's duration is excluded even when its lane uploaded an artifact.
In particular, run 36664663190's serial 5 finished in 22m15s with an assertion failure, not a timeout; treating that as a healthy whole-lane sample would hide the failure.
Collect successful per-script measurements for every member before calculating a split.

`tests/fm-supervision-host.test.sh` was set to 789123 ms from run 36669175457 on the upstream repository, after its merged [host runtime fix](https://github.com/kunchenguid/firstmate/pull/6179).
The fork's own runners did not reproduce that value, as the 2026-10-21 refresh below records.
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms measurement from 2026-09-06T21:02Z instead of a portable capability skip.
The session-start hint retains its pre-optimization maximum until CI measures the shorter fixture-only home-summary bound; do not discount a local speedup from CI packing weights.

### Fork refresh, 2026-10-21

The fork's `Behavior portable serial 2` job reached its 30-minute cap on main run [39613397657](https://github.com/rub-a-dub-dub/firstmate/actions/runs/39613397657) and three times on pull request 46, including run [39617554991](https://github.com/rub-a-dub-dub/firstmate/actions/runs/39617554991).
Of those four cancellations only the two runs cited above contributed samples; the shard-2 job of each uploaded no artifact, so their shard-2 scripts have no successful sample there.
The serial hints were raised from the slowest successful `duration_ms` across the portable serial timing artifacts of nine fork runs: [38534017843](https://github.com/rub-a-dub-dub/firstmate/actions/runs/38534017843), [38818232706](https://github.com/rub-a-dub-dub/firstmate/actions/runs/38818232706), [38826348620](https://github.com/rub-a-dub-dub/firstmate/actions/runs/38826348620), [39486507769](https://github.com/rub-a-dub-dub/firstmate/actions/runs/39486507769), [39489965358](https://github.com/rub-a-dub-dub/firstmate/actions/runs/39489965358), [39589765073](https://github.com/rub-a-dub-dub/firstmate/actions/runs/39589765073), the nine shards of the first repacked pull request 47 run [39644788352](https://github.com/rub-a-dub-dub/firstmate/actions/runs/39644788352), and the eight completed shards of each of those two cancelled runs.
The cause was the host suite, not the disk-sweep test.
`tests/fm-disk-sweep.test.sh` measured 5232 to 5561 ms in four runs, and its hint is 5561 ms.
`tests/fm-supervision-host.test.sh` measured 900666 to 1711444 ms in seven successful samples, against its 789123 ms hint, so the old split packed it beside 20 other scripts and that shard accumulated 1.1 to 1.56 million ms of script time.
It is now hinted at its slowest sample of 1711444 ms, from the repacked run where it alone filled a 29m34s job, and the partition places it alone, as it already placed `tests/fm-watch-triage.test.sh`, now hinted at its slowest sample of 1218807 ms.
The other seven shards model at about 19.8 minutes each.
Every hint below its slowest successful fork sample was raised to that sample, including the 11 serial scripts that had no hint at all, and a hint already above every fork sample keeps its earlier, higher value, so each entry is still the slowest successful sample across the runs this file references.
The host floor sits above the former 20-minute packing target, so `PORTABLE_SERIAL_MAX_WEIGHT_MS` is now 35 minutes, which leaves ten minutes of the 45-minute serial shard cap and about 23 percent of headroom over that indivisible floor.
The host alone reached 29m34s of the old 30-minute cap, so the serial shard jobs now run under their own 45-minute tripwire in the Timeouts policy below.
Splitting that suite is the real remedy for its duration, and a larger cap is only the safeguard until that lands.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints, with the Pi typecheck pinned to the job that installs its prerequisite.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap follows the four-tier timeout policy in [Timeouts](#timeouts) below.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
[Verification inputs](#verification-inputs) owns the measurement provenance and exceptions.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.
That catches missing hints, not stale existing hints: the host suite still had a 41512 ms hint after growing to over 1000 seconds in CI, so the old split placed it beside another 12 minutes of work while passing the guard.
Refresh the hints whenever a serial member grows materially or the lane gains scripts, rather than waiting for missing-hint coverage to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
Its header and `--help` own the modeled-budget check and output fields; read the current estimates from `--check-coverage` instead of retaining copied lane sums here.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_serial_packing_budget_boundary`, verifies acceptance exactly at the budget and refusal one millisecond above it through the executable runner.
The longest script, `tests/fm-supervision-host.test.sh`, is the indivisible floor for this layout, with `tests/fm-watch-triage.test.sh` next.
The estimates use per-file maxima from different runs, not measured rebalanced jobs or an end-to-end latency guarantee.
The fork's host samples range from 900666 to 1711444 ms and its watch-triage samples from 973174 to 1218807 ms.
The 30-second ceiling on job overhead beyond summed scripts was observed in the 2026-09-30 baseline runs; the fork's host-alone shard on run 39644788352 ran 29m34s against 1711444 ms of script time, about 63 seconds of job overhead, so allow at least that much above a modeled shard weight.
Even so, maxima from a few runs do not establish a P95 or guarantee future headroom.
Job timeouts remain hang tripwires under the policy in [Timeouts](#timeouts) below; they are not the desired healthy duration.
`tests/fm-ci-workflow.test.sh` compares the parsed CI matrix to the executable runner lanes, and the runner rejects parallel `--jobs` on a serial lane even when that shard has only one member.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh-axi run download "$run" --dir "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/fm-test-timing-portable-serial-*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

Run this in the checkout whose CI you are measuring, since `gh-axi run download` resolves the repository from the working directory and the run IDs must belong to it.
A timed-out shard may upload no artifact, so include a complete green run or the slowest scripts go unmeasured in exactly the shard that needs them most.
Completed shards from a partial run can supplement that complete baseline, but never treat missing tail scripts or the timeout duration as successful samples.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
Its hint-coverage and modeled-budget checks are described in [Portable serial CI shards](#portable-serial-ci-shards); neither replaces inspection of actual CI timing artifacts.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns two canonical CI partitions, each attempting full source-aware ShellCheck analysis and running workflow validation and backend-purity checks.
CI requires its per-root bounds, so an unenforceable deadline or address-space limit refuses lint rather than running uncapped; the script header owns the envelope, per-root execution contract, and memory fallback.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots, initial analysis flags, and fallback reporting.
The workflow uploads each partition's quiet telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, or paid runner provisioning is part of this layout.

The longer-term performance objective remains a complete green run under fifteen minutes including start delay, but the current host floor alone exceeds that objective.
The immediate packing target is the runner's modeled script budget, not a claim that more shards alone can make an indivisible script faster.
The layout uses fourteen long-lived Linux jobs (nine serial, two parallel, Herdr, two lint), plus short checks and macOS; insufficient shared account capacity can erase the packing gain.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The workflow retains per-PR supersession without cancelling main pushes or changing the compliance workflow's event semantics.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

CI job timeouts follow one four-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A lane that reaches its tier bound needs investigation and a distribution or runtime fix, not a larger timeout to fit the same work.
The one exception is a lane whose indivisible floor is a single script already above its tier: it earns its own tier bound until that script is split, which stays the real remedy.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | coverage guard, repo invariants, timing aggregate | 5 minutes | Seconds-long local work, so the tripwire only catches a hung runner. |
| Normal | lint partitions, portable parallel shards, macOS stock Bash | 30 minutes, one value shared by every job in the tier | One shared hang tripwire keeps every ordinary test and lint lane on the same policy instead of allowing per-lane packing estimates or one-off caps to set the bound. |
| Serial shard | portable serial shards | 45 minutes | The indivisible supervision-host suite alone ran 29m34s of the former 30-minute cap, so these shards keep a tripwire above the normal tier while the suite stays whole. |
| Heavy | Herdr | family-run step 20 minutes under a 75-minute job-level last-resort backstop | Healthy runs finish in about 7-10 minutes, so the step tripwire fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values and names each job's tier beside its `timeout-minutes`.
[`tests/fm-ci-workflow.test.sh`](../tests/fm-ci-workflow.test.sh) holds the policy against the parsed workflow: every job belongs to exactly one tier, the workflow carries exactly four distinct job-level values, the fast tier stays within 5-10 minutes, the normal jobs share one 30-minute budget, the serial shards share one 45-minute tripwire between the normal and heavy tiers that still leaves ten minutes above the runner's reported `serial_budget_ms`, and the Herdr family-run step is the 20-minute tripwire below its job backstop with an `always()` teardown after it.
A passing coverage guard does not establish a healthy job duration; refresh the healthy figures above from the lanes' uploaded timing artifacts.
