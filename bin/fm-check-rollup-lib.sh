# shellcheck shell=bash
# Shared "what does the current run of each named check say" rule.
# Usage: . bin/fm-check-rollup-lib.sh; splice "$FM_CHECK_ROLLUP_JQ_DEFS" ahead
# of a jq program that reads a live pull-request JSON's .statusCheckRollup,
# then call check_rollup_verdicts to get one {name, kind, ok, pending} object
# per reported check.
#
# ONE OWNER for the check-rollup verdict. bin/fm-pr-merge.sh's merge gate and
# bin/fm-bearings-snapshot.sh's PR-checks summary both answer the one question
# "does the CURRENT run of this named check say it is green", so the rule
# lives here and neither program restates it.
#
# THE ORDERING KEY. GitHub cancels a pull request's in-flight run when the
# base branch advances and re-triggers it, and a no-mistakes pipeline that
# re-attests after a first failed run leaves the same shape: several runs of
# one check NAME at the identical head, the oldest reporting a conclusion a
# later one superseded. The rollup keeps every one of them; only the current
# run is the verdict. startedAt is the ordering key, not completedAt or a run
# database id: GitHub's own combined-status computation for mergeStateStatus
# already orders same-context reports this way, so agreeing with it is what
# keeps this rule from refusing a pull request GitHub itself considers
# mergeable, and unlike completedAt it is not reordered by which run happens
# to finish last (a fast failure can finish after a slow pass that started
# after it - see the "late-finishing" cases below). Verified directly against
# a live incident: rub-a-dub-dub/firstmate PR 10's head carried a FAILURE run
# of "PR must be raised via no-mistakes" at 05:59:46 and a SUCCESS re-run of
# the same check at 06:00:27, and ordering by startedAt is what makes this
# rule call it green while a completedAt-only reading of a slower stale run
# finishing later could not be ruled out without the same startedAt check.
#
# Supersession applies only among check runs with the same reported name. A
# name is dropped from the red set only when every non-green run is COMPLETED,
# has a whole-second UTC startedAt, and started strictly before a green run.
# Status contexts are never grouped or superseded, and every non-green one is
# judged on its own current state. A still-running, queued, undated, or tied
# check run keeps its name not-green (never a proven pass), and is reported
# pending rather than red only when the reason is that something is still
# resolving, not a genuine failure - callers that only need a merge/refuse
# answer read ok and can ignore pending. A name whose runs are all green needs
# no timestamp, while a name with no green run stays not-green regardless.
#
# The reported name is also what bin/fm-pr-merge.sh's --allow-red matches. An
# unnamed check run is grouped alone and can neither supersede nor be
# superseded, because unrelated unnamed checks must not be treated as one.

# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
# shellcheck disable=SC2016 # jq's own $vars are literal jq syntax, never bash expansion.
FM_CHECK_ROLLUP_JQ_DEFS='
  def settled_at:
    if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
    then . else null end;
  def check_rollup_normalize:
    to_entries[]
    | .key as $i
    | .value
    | if .__typename == "CheckRun" then
        {
          kind: "check_run",
          name: (.name // ""),
          completed: (.status == "COMPLETED"),
          ok: (.status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")),
          at: (.startedAt | settled_at)
        }
        | . + {group: (if .name == "" then ["", $i] else [.name, -1] end)}
      else
        {
          kind: "status_context",
          name: (.context // ""),
          completed: true,
          ok: (.state == "SUCCESS"),
          pending_state: ((.state != "SUCCESS") and (.state != "FAILURE") and (.state != "ERROR")),
          group: ["status_context", (.context // ""), $i]
        }
      end;
  def check_rollup_group_verdict:
    . as $group
    | ($group[0].kind) as $kind
    | ($group[0].name) as $name
    | if $kind == "status_context" then
        {name:$name, kind:$kind, ok:$group[0].ok, pending:(($group[0].ok|not) and $group[0].pending_state)}
      else
        ([$group[] | select(.ok | not)]) as $reds
        | if ($reds | length) == 0 then
            {name:$name, kind:$kind, ok:true, pending:false}
          elif any($reds[]; .completed | not) then
            {name:$name, kind:$kind, ok:false, pending:true}
          else
            ([$group[] | select(.ok) | .at | select(. != null)] | max) as $newest_green
            | if $newest_green != null
                and (all($reds[]; .at != null))
                and (([$reds[] | .at] | max) < $newest_green)
              then {name:$name, kind:$kind, ok:true, pending:false}
              else {name:$name, kind:$kind, ok:false, pending:false}
              end
          end
      end;
  def check_rollup_verdicts:
    [.statusCheckRollup // [] | check_rollup_normalize]
    | group_by(.group)[]
    | check_rollup_group_verdict;
'
