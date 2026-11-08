#!/bin/bash
# Benchmark MadNLP.jl on machines of your own, with the website coordinating them and building the
# report. Two steps: create a job once, then run it on as many machines as you like.
#
#     runner/publish.sh new [master|PR-NUMBER|BRANCH|COMMIT] [--devices=cpu|cuda|cpu,cuda] [--config=NAME]
#                           [--options=name=value,...] [--sets=acopf,cops,...] [--job-file=PATH]
#     runner/publish.sh run --job-file=PATH [--hsl=PATH] [--work=DIR] [--depot=DIR] [--every=SECONDS]
#
# `new` asks the website for a job, with a GitHub token of someone with write access to MadNLP.jl
# (BENCHMARK_TOKEN, or `gh auth token`), and writes the job's number and its own token to the job
# file (./benchmark-job-<number>, mode 600). The job's settings are fixed there and then.
#
# `run` makes this machine a node of the job: it takes the job's settings from the website, clones
# that commit of MadNLP.jl, sets up this harness, and solves the instances the website hands out,
# sending what changed every --every seconds (15). Start it on as many machines as you like, at
# once or later: the website gives each instance to one of them and merges their results into one
# report. The job file is all a node needs; no GitHub token.
#
# Stopping is safe at any time (a batch job preempted, say): the instances a stopped node held go
# to the others after 10 minutes, and running it again with the same work directory carries on
# where it left off. The work directory (default ./benchmark-work/job<N>-<batch job or host>) holds
# the clone, the Julia depot (a few GB; --depot shares one between the nodes of a cluster, which
# then install and compile once) and the node's results. --hsl is a licensed HSL_jll for
# MA57 on the host; without it the host uses MUMPS. The node uses what it is given: on a cluster,
# the batch job's cores, and 2 workers per GPU it sees.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
site=${BENCHMARK_SITE:-https://benchmark.madsuite.org}
cmd=${1:-}; shift || true
what=master devices=cpu,cuda config=default options="" sets="" jobfile="" hsl="" work="" depot="" every=15
for a in "$@"; do
    case "$a" in
        --devices=*) devices=${a#*=} ;; --config=*) config=${a#*=} ;; --options=*) options=${a#*=} ;;
        --sets=*) sets=${a#*=} ;; --job-file=*) jobfile=${a#*=} ;; --hsl=*) hsl=$(cd "${a#*=}" && pwd) ;;
        --work=*) work=${a#*=} ;; --depot=*) depot=${a#*=} ;; --every=*) every=${a#*=} ;;
        --*) echo "publish: unknown option $a" >&2; exit 2 ;;
        *) what=$a ;;
    esac
done
# a field of the website's JSON answers: a string, or a number
json_field() { local t; t=$(cat); sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" <<< "$t" | head -1 | grep . || sed -n "s/.*\"$1\": *\([0-9][0-9]*\).*/\1/p" <<< "$t" | head -1; }

if [ "$cmd" = new ]; then
    token=${BENCHMARK_TOKEN:-$(gh auth token 2>/dev/null)}
    [ -n "$token" ] || { echo "publish: no GitHub token; set BENCHMARK_TOKEN or sign in with gh" >&2; exit 2; }
    if [ "$what" = master ]; then target='"master": true'
    elif [[ $what =~ ^#?[0-9]+$ ]]; then target="\"pr\": ${what#\#}"
    elif [[ $what =~ ^[0-9a-f]{40}$ ]]; then target="\"commit\": \"$what\""
    elif [[ $what =~ ^[A-Za-z0-9._/-]+$ ]]; then target="\"branch\": \"$what\""
    else echo "publish: give master, a pull request number, a branch or a commit" >&2; exit 2; fi
    [[ $config =~ ^[a-z0-9_]+$ && $devices =~ ^(cpu|cuda|cpu,cuda)$ && $options =~ ^[A-Za-z0-9_.,=+-]*$ && $sets =~ ^[a-z,]*$ ]] ||
        { echo "publish: bad --config, --devices, --options or --sets" >&2; exit 2; }
    body="{\"external\": true, $target, \"devices\": \"$devices\", \"config\": \"$config\", \"options\": \"$options\"${sets:+, \"sets\": \"$sets\"}}"
    out=$(curl -sS -H @<(printf 'Authorization: Bearer %s\n' "$token") -H "Content-Type: application/json" --data-binary "$body" "$site/queue/api/jobs") ||
        { echo "publish: $site cannot be reached" >&2; exit 2; }
    id=$(json_field id <<< "$out") jtoken=$(json_field token <<< "$out")
    [[ $id =~ ^[0-9]+$ && -n $jtoken ]] || { echo "publish: the website refused: $out" >&2; exit 2; }
    jobfile=${jobfile:-$PWD/benchmark-job-$id}
    (umask 077; printf '%s %s %s\n' "$site" "$id" "$jtoken" > "$jobfile")
    echo "job $id: $(json_field sha <<< "$out"), $devices, $config${options:+, $options}"
    echo "report: $(json_field report <<< "$out")"
    echo "job file: $jobfile (run each node with: runner/publish.sh run --job-file=$jobfile)"
    exit 0
fi

[ "$cmd" = run ] || { echo "usage: runner/publish.sh new ... | runner/publish.sh run --job-file=PATH (see the top of this file)" >&2; exit 2; }
[ -r "$jobfile" ] || { echo "publish: give --job-file, written by runner/publish.sh new" >&2; exit 2; }
read -r site id jtoken < "$jobfile"
[[ $id =~ ^[0-9]+$ ]] || { echo "publish: $jobfile is not a job file" >&2; exit 2; }
[[ $every =~ ^[0-9]+$ ]] && [ "$every" -ge 5 ] || { echo "publish: --every is at least 5 seconds" >&2; exit 2; }
api=$site/queue/api/jobs/$id
work=${work:-$PWD/benchmark-work/job$id-${SLURM_JOB_ID:-$(hostname -s)}}
depot=${depot:-$work/depot}
mkdir -p "$work/results" "$depot"
work=$(cd "$work" && pwd)
# the job's token goes to curl through a file, never on a command line others can see
auth=$work/auth.header
(umask 077; printf 'Authorization: Bearer %s\n' "$jtoken" > "$auth")
# this node's name, kept in the work directory, so that a node started again is the same node
[ -s "$work/node" ] || od -An -N6 -tx1 /dev/urandom | tr -d ' \n' > "$work/node"
node=$(cat "$work/node")
host=$(hostname -s)
log=$work/publish.log
exec > >(tee -a "$log") 2>&1

spec=$(curl -sS -m 60 -H @"$auth" "$api/spec") || { echo "publish: $site cannot be reached" >&2; exit 3; }
sha=$(json_field sha <<< "$spec") state=$(json_field state <<< "$spec")
[[ $sha =~ ^[0-9a-f]{40}$ ]] || { echo "publish: the website refused: $spec" >&2; exit 3; }
[ "$state" = running ] || { echo "publish: job $id is $state"; exit 0; }
devices=$(json_field devices <<< "$spec") config=$(json_field config <<< "$spec") options=$(json_field options <<< "$spec")
sets=$(json_field sets <<< "$spec")
echo "publish: job $id node $node on $host, $sha, $devices, $config${options:+, $options}, $(date -u '+%F %T') UTC"

# what changed since the last time, and this node's log; the answer says whether to stop
marker=$work/.sent
send() {   # state
    local list=$work/.list next=$work/.sent.next
    touch "$next"
    (cd "$work/results" && if [ -e "$marker" ]; then find . -type f -newer "$marker"; else find . -type f; fi) |
        grep -E '\.(csv|toml|md|txt)$' > "$list"
    mkdir -p "$work/.log" && tail -n 3000 "$log" > "$work/.log/job.log"
    tar czf "$work/.send.tar.gz" -C "$work/results" -T "$list" -C "$work/.log" job.log 2>/dev/null
    local out
    out=$(curl -sS -m 300 -H @"$auth" --data-binary @"$work/.send.tar.gz" "$api/files?node=$node&state=$1&host=$host") || return 0
    if [[ $out == *'"cancel": false'* || $out == *'"cancel": true'* ]]; then
        mv "$next" "$marker"
    else
        echo "publish: the website did not take the files: $(head -c 300 <<< "$out")"
    fi
    [[ $out == *'"cancel": true'* ]]
}

if [ -d "$work/madnlp/.git" ]; then git -C "$work/madnlp" fetch -q origin || exit 3
else git clone -q https://github.com/madsuite-org/MadNLP.jl "$work/madnlp" || exit 3; fi
git -C "$work/madnlp" checkout -q --detach "$sha" || exit 3
rm -rf "$work/harness" && cp -a "$here" "$work/harness" && rm -rf "$work/harness/.git" "$work/harness/madnlp" "$work/harness/.claude" || exit 3
cd "$work/harness"
export JULIA_DEPOT_PATH="$(readlink -f "$depot")"
julia --startup-file=no setup.jl "$work/madnlp" ${hsl:+--hsl=$hsl} || { send failed; exit 4; }
export BENCHMARK_CLAIM=$api/claim BENCHMARK_AUTH=$auth BENCHMARK_NODE=$node
julia --startup-file=no --project=. run.jl "${sets:-acopf,cops,mittelmann,cutest}" --device="$devices" --config="$config" \
    ${options:+"--options=$options"} --root="$work/results" < /dev/null &
bench=$!
# stopped (preempted, cancelled): say so, and keep what there is; running this again carries on
trap 'kill $bench 2>/dev/null; wait $bench; send interrupted; exit 143' TERM INT
while kill -0 $bench 2>/dev/null; do
    sleep "$every" & wait $!
    if kill -0 $bench 2>/dev/null && send running; then
        echo "publish: job $id was cancelled"; kill $bench; wait $bench; send cancelled; exit 0
    fi
done
wait $bench; rc=$?
if [ $rc -eq 0 ]; then send finished; else send failed; fi
echo "publish: node $node done ($rc), $(json_field report <<< "$spec")"
exit $rc
