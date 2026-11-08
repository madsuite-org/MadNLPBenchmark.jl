#!/bin/bash
# Run the benchmark on this machine and publish its results on the website while it runs.
#
#     runner/publish.sh NAME [REV] [--devices=cpu|cuda|cpu,cuda] [--sets=acopf,cops,...] [--config=NAME]
#                       [--options=name=value,...] [--hsl=PATH] [--work=DIR] [--every=SECONDS] [--fresh]
#
# NAME names the report, https://benchmark.madsuite.org/madnlp/run-up-NAME/ (lowercase letters,
# digits and -). REV is the commit, branch or tag of MadNLP.jl to benchmark, master by default.
# The results are uploaded every --every seconds (300) while the run goes, and once more at its end.
#
# The upload takes a GitHub token of someone with write access to MadNLP.jl, from BENCHMARK_TOKEN
# or else `gh auth token`. Needs julia, git, curl and tar. --hsl is a licensed HSL_jll for MA57 on
# the host; without it the host's default configuration uses MUMPS. The work directory (default
# ./benchmark-work) holds the clone, the Julia depot (a few GB) and the results; running again
# with the same one carries on from the results it has, unless --fresh. On a cluster, run this
# inside a batch job: the workers follow the job's allocation and the GPUs it sees.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
name="" rev=master devices=cpu,cuda sets=acopf,cops,mittelmann,cutest config=default options="" hsl="" work=$PWD/benchmark-work every=300 fresh=0
for a in "$@"; do
    case "$a" in
        --devices=*) devices=${a#*=} ;; --sets=*) sets=${a#*=} ;; --config=*) config=${a#*=} ;;
        --options=*) options=${a#*=} ;; --hsl=*) hsl=$(cd "${a#*=}" && pwd) ;; --work=*) work=${a#*=} ;;
        --every=*) every=${a#*=} ;; --fresh) fresh=1 ;;
        --*) echo "publish: unknown option $a" >&2; exit 2 ;;
        *) if [ -z "$name" ]; then name=$a; else rev=$a; fi ;;
    esac
done
site=${BENCHMARK_SITE:-https://benchmark.madsuite.org}
[[ $name =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { echo "usage: runner/publish.sh NAME [REV] [options]; NAME is lowercase letters, digits and -" >&2; exit 2; }
[[ $devices =~ ^(cpu|cuda|cpu,cuda)$ ]] || { echo "publish: --devices is cpu, cuda or cpu,cuda" >&2; exit 2; }
[[ $every =~ ^[0-9]+$ ]] && [ "$every" -ge 60 ] || { echo "publish: --every is at least 60 seconds" >&2; exit 2; }

# the token goes to curl through a file descriptor, never on a command line others can see
token=${BENCHMARK_TOKEN:-$(gh auth token 2>/dev/null)}
[ -n "$token" ] || { echo "publish: no token; set BENCHMARK_TOKEN or sign in with gh" >&2; exit 2; }
auth() { printf 'Authorization: Bearer %s\n' "$token"; }
me=$(curl -sS -H @<(auth) "$site/queue/api/me") || { echo "publish: $site cannot be reached" >&2; exit 2; }
[[ $me == *'"can_run": true'* ]] || { echo "publish: the token cannot publish: $me" >&2; exit 2; }

mkdir -p "$work"
work=$(cd "$work" && pwd)
[ "$fresh" = 1 ] && rm -rf "$work/results"
mkdir -p "$work/results"
# the depot by its real path, as Julia records the path it was given in what it installs
mkdir -p "$work/depot"
export JULIA_DEPOT_PATH="$(readlink -f "$work/depot")"
log=$work/publish.log
exec > >(tee -a "$log") 2>&1

upload() {   # state; a run with no complete result file yet has nothing to show
    find "$work/results" -name '*.csv.meta.toml' | grep -q . || return 0
    cp "$log" "$work/results/job.log" 2>/dev/null
    tar czf "$work/upload.tar.gz" -C "$work/results" . &&
        curl -sS -H @<(auth) --data-binary @"$work/upload.tar.gz" "$site/queue/api/results?name=$name&state=$1" | head -c 300
    echo
}

echo "publish: $name, MadNLP.jl $rev, $devices, $(date -u '+%F %T') UTC, on $(hostname)"
if [ -d "$work/madnlp/.git" ]; then
    git -C "$work/madnlp" fetch -q origin || exit 3
else
    git clone -q https://github.com/madsuite-org/MadNLP.jl "$work/madnlp" || exit 3
fi
sha=$(git -C "$work/madnlp" rev-parse --verify -q "origin/$rev^{commit}" || git -C "$work/madnlp" rev-parse --verify -q "$rev^{commit}") ||
    { echo "publish: no commit $rev in MadNLP.jl" >&2; exit 3; }
git -C "$work/madnlp" checkout -q --detach "$sha" || exit 3
echo "publish: benchmarking $sha"
# the harness is a copy, so that this checkout is left as it is
rm -rf "$work/harness" && cp -a "$here" "$work/harness" && rm -rf "$work/harness/.git" "$work/harness/madnlp" "$work/harness/.claude" || exit 3
cd "$work/harness"
julia --startup-file=no setup.jl "$work/madnlp" ${hsl:+--hsl=$hsl} || exit 4
julia --startup-file=no --project=. run.jl "$sets" --device="$devices" --config="$config" ${options:+"--options=$options"} \
    --root="$work/results" < /dev/null &
bench=$!
trap 'kill $bench 2>/dev/null; wait $bench; upload failed; exit 143' TERM INT
while kill -0 $bench 2>/dev/null; do
    sleep "$every" & wait $!
    kill -0 $bench 2>/dev/null && upload running
done
wait $bench; rc=$?
if [ $rc -eq 0 ]; then upload finished; else upload failed; fi
echo "publish: done, $site/madnlp/run-up-$name/"
exit $rc
