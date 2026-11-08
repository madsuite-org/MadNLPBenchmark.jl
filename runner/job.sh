#!/bin/bash
# One benchmark job: the commit of MadNLP.jl, run with this harness, its results copied to the live
# folder that the website watches. Started by runner.py as the job user, in a unit of its own.
#
#     job.sh LIVE_FOLDER SHA KIND PR [keep|fresh] [CONFIG] [OPTIONS] [HARNESS] [DEVICES]
#
# CONFIG is a configuration of configs.toml, `default` if not given, and OPTIONS extra options of
# MadNLP on top of it, as run.jl's --options takes them; run.jl checks both. HARNESS is a branch of
# this repository to run instead of the harness this script belongs to, for an experiment; never
# for master. DEVICES is cpu, cuda or cpu,cuda, the last by default.
#
# With `keep` the run takes over the results already in LIVE_FOLDER, from an earlier commit of the
# same pull request, and solves only the rest; with `fresh` it throws them away first.
#
# Writes only LIVE_FOLDER and $JOB_HOME (scratch, Julia depot, results). Every 5 s it copies the
# results and then replaces run.json, which is what makes the website rebuild.
set -u
live=$1 sha=$2 kind=$3 pr=$4 mode=${5:-keep} config=${6:-default} options=${7:-} branch=${8:-} devices=${9:-cpu,cuda}
[[ $config =~ ^[a-z0-9_]+$ ]] || { echo "job: bad configuration $config" >&2; exit 2; }
[[ $devices =~ ^(cpu|cuda|cpu,cuda)$ ]] || { echo "job: bad devices $devices" >&2; exit 2; }
if [ -n "$branch" ]; then
    [[ $branch =~ ^[A-Za-z0-9._/-]{1,100}$ && $branch != *..* ]] || { echo "job: bad harness branch $branch" >&2; exit 2; }
    [ "$kind" != master ] || { echo "job: a run of master uses the harness of main" >&2; exit 2; }
fi
harness=$(cd "$(dirname "$0")/.." && pwd)
work=${JOB_HOME:?}
repository=${JOB_REPOSITORY:-madsuite-org/MadNLP.jl}
export JULIA_DEPOT_PATH="$work/depot:${JOB_SHARED_DEPOT:-}"
mkdir -p "$work/results" "$live"
if [ "$mode" = fresh ]; then
    find "$live" -mindepth 1 -delete
else
    rsync -a --exclude=run.json --exclude=job.log --exclude='.*' "$live"/ "$work/results"/
fi
# the job's own log, beside its results, so that a failure explains itself on the website
exec > >(tee -a "$live/job.log") 2>&1
echo "job: $kind ${pr:+#$pr }at $sha, $(date -u '+%F %T') UTC, on $(hostname)"

run_json() {
    local title="" 
    [ "$kind" = master ] && title="master ${sha:0:8}"
    printf '{"repository":"%s","pr":"%s","commit":"%s","title":"%s","state":"%s"}\n' "$repository" "$pr" "$sha" "$title" "$1" > "$live/.run.json"
    mv "$live/.run.json" "$live/run.json"
}
copy() {
    rsync -a --exclude='*.tmp' --exclude=job.log "$work/results"/ "$live"/ && run_json "$1"
}
stop() {
    kill "${beat:-}" "${bench:-}" 2>/dev/null; wait "${bench:-}" 2>/dev/null
    copy cancelled; exit 143
}
fail() {
    kill "${beat:-}" 2>/dev/null; copy failed; exit "$1"
}
trap stop TERM INT

run_json running
# until the run copies results, say every 5 s that the job is alive, so a long setup is not taken
# for a stalled run
( while :; do sleep 5; run_json running; done ) &
beat=$!
# the commit to benchmark, checked to be the one asked for
git clone -q "${JOB_SOURCE:-https://github.com/$repository}" "$work/madnlp" && git -C "$work/madnlp" checkout -q --detach "$sha" \
    && [ "$(git -C "$work/madnlp" rev-parse HEAD)" = "$sha" ] || fail 2
# the harness is a copy, or a clone of the branch asked for: the job may not change what the next job runs
if [ -n "$branch" ]; then
    git clone -q --depth 1 --branch "$branch" "${JOB_HARNESS_SOURCE:-https://github.com/madsuite-org/MadNLPBenchmark.jl}" "$work/harness" \
        && echo "job: harness branch $branch at $(git -C "$work/harness" rev-parse HEAD)" || fail 4
    rm -rf "$work/harness/.git" "$work/harness/madnlp"
else
    cp -a "$harness" "$work/harness" && rm -rf "$work/harness/.git" "$work/harness/madnlp"
fi
cd "$work/harness"
julia --startup-file=no setup.jl "$work/madnlp" ${JOB_HSL:+--hsl=$JOB_HSL} || fail 3
unset CUDA_VISIBLE_DEVICES
julia --startup-file=no --project=. run.jl ${JOB_SETS:-acopf,cops,mittelmann,cutest} --device="$devices" --config="$config" ${options:+"--options=$options"} \
    --wall=${JOB_WALL:-7200} --cuda-wall=${JOB_CUDA_WALL:-600} --root="$work/results" < /dev/null &
bench=$!
kill "$beat" 2>/dev/null
while kill -0 "$bench" 2>/dev/null; do copy running; sleep 5 & wait $!; done
wait "$bench"; rc=$?
if [ $rc -eq 0 ]; then copy finished; else copy failed; fi
exit $rc
