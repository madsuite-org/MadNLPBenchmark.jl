#!/bin/bash
# Benchmark MadNLP.jl on machines of your own, with the website coordinating them and building the
# report. Two steps: create a job once, then run it on as many machines as you like.
#
#     runner/publish.sh new [master|PR-NUMBER|BRANCH|COMMIT|--local=PATH] --note=TEXT [--devices=cpu|cuda|cpu,cuda] [--config=NAME]
#                           [--options=name=value,...] [--sets=acopf,cops,...] [--subset=TERMS] [--instances=a,b,...|@FILE]
#                           [--label=TEXT] [--job-file=PATH]
#     runner/publish.sh run --job-file=PATH [--madnlp=PATH] [--hsl=PATH] [--work=DIR] [--depot=DIR] [--src=DIR] [--every=SECONDS]
#
# Local code: `new --local=PATH` makes a job of the checkout of MadNLP.jl at PATH, as it is (its
# commit, and its uncommitted changes, by a hash), which need not be on GitHub; its nodes run that
# checkout, `run --madnlp=PATH`, and check it is the same. The website marks such a run as local code
# (nobody else can reproduce it) and never takes it for a reference. A pull request from a fork is
# fetched from MadNLP.jl itself (refs/pull/<N>/head), and marked as a fork's.
#
# `new` asks the website for a job, with a GitHub token of someone with write access to MadNLP.jl
# (BENCHMARK_TOKEN, or `gh auth token`), and writes the job's number and its own token to the job
# file (./benchmark-job-<number>, mode 600). The job's settings are fixed there and then. --note says
# what the job is for ("baseline for #712", "test of ..."), shown with its report; it is required, so
# that every run on the website says why it is there. A job can
# run over a subset: --subset takes terms that every instance meets, joined by commas (size=small+
# medium+large, constrained=yes|no, failed=SOURCE, solved=SOURCE, resto=SOURCE, a source being
# ipopt, the Ipopt reference, or a report such as run-x50-1b00be2e), --instances a list of names
# (or @FILE, one per line); the website resolves them against what it knows then, and keeps the list.
# --label names the job's column in reports; a report, which compares runs, is made on the website
# (POST /queue/api/reports, or the report's page).
#
# `run` makes this machine a node of the job: it takes the job's settings from the website, clones
# that commit of MadNLP.jl, sets up this harness, and solves the instances the website hands out,
# sending what changed every --every seconds (5). Start it on as many machines as you like, at
# once or later: the website gives each instance to one of them and merges their results into one
# report. The job file is all a node needs; no GitHub token.
#
# Stopping is safe at any time: the instances a stopped node held go
# to the others after 10 minutes, and running it again with the same work directory carries on
# where it left off. The work directory (default ./benchmark-work/job<N>-<host>) holds
# the clone, the Julia depot (a few GB) and the node's results. On a shared file system, give the nodes one
# --depot and one --src on a shared file system: the depot holds the installed and compiled
# packages (and what is compiled, per kind of processor), --src the checkout of each commit set up
# with this harness, made by the first node while the others wait. Nodes then install once and
# compile once per kind of processor, and a later job reuses what an earlier one compiled. --hsl is a licensed HSL_jll for
# MA57 on the host; without it the host uses MUMPS. The node uses what it is given: the cores it
# may use, and 2 workers per GPU it sees.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
site=${BENCHMARK_SITE:-https://benchmark.madsuite.org}
cmd=${1:-}; shift || true
note="" label="" local="" madnlp="" what=master devices=cpu,cuda config=default options="" sets="" subset="" instances="" jobfile="" hsl="" work="" depot="" src="" every=5
for a in "$@"; do
    case "$a" in
        --devices=*) devices=${a#*=} ;; --config=*) config=${a#*=} ;; --options=*) options=${a#*=} ;;
        --sets=*) sets=${a#*=} ;; --job-file=*) jobfile=${a#*=} ;; --hsl=*) hsl=$(cd "${a#*=}" && pwd) ;;
        --note=*) note=${a#*=} ;; --label=*) label=${a#*=} ;; --subset=*) subset=${a#*=} ;; --instances=@*) instances=$(grep -v '^\s*$' "${a#*=@}" | paste -sd, -) ;; --instances=*) instances=${a#*=} ;;
        --local=*) local=${a#*=} ;; --madnlp=*) madnlp=${a#*=} ;; --work=*) work=${a#*=} ;; --depot=*) depot=${a#*=} ;; --src=*) src=${a#*=} ;; --every=*) every=${a#*=} ;;
        --*) echo "publish: unknown option $a" >&2; exit 2 ;;
        *) what=$a ;;
    esac
done
# a field of the website's JSON answers: a string, or a number
json_field() { local t; t=$(cat); sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" <<< "$t" | head -1 | grep . || sed -n "s/.*\"$1\": *\([0-9][0-9]*\).*/\1/p" <<< "$t" | head -1; }

local_changes() {   # checkout
    local d
    d=$(cd "$1" && { git diff HEAD --binary; git ls-files --others --exclude-standard -z | xargs -0 -r sha1sum; } 2>/dev/null)
    [ -z "$d" ] || sha1sum <<< "$d" | cut -c1-40
}

if [ "$cmd" = new ]; then
    token=${BENCHMARK_TOKEN:-$(gh auth token 2>/dev/null)}
    [ -n "$token" ] || { echo "publish: no GitHub token; set BENCHMARK_TOKEN or sign in with gh" >&2; exit 2; }
    # the uncommitted changes of a checkout, as one hash ("" without any): tracked files against its
    # commit, and the untracked ones
    if [ -n "$local" ]; then
        git -C "$local" rev-parse --verify -q HEAD >/dev/null || { echo "publish: $local is not a git checkout" >&2; exit 2; }
        lsha=$(git -C "$local" rev-parse HEAD)
        lchanges=$(local_changes "$local")
        lname=$(git -C "$local" rev-parse --abbrev-ref HEAD | tr -c 'A-Za-z0-9._/+-' '-' | cut -c1-60)
        target="\"local\": {\"commit\": \"$lsha\", \"changes\": \"$lchanges\", \"name\": \"${lname%-}\"}"
        echo "publish: local code at $lsha${lchanges:+ with uncommitted changes}: only machines with this checkout can run it"
    elif [ "$what" = master ]; then target='"master": true'
    elif [[ $what =~ ^#?[0-9]+$ ]]; then target="\"pr\": ${what#\#}"
    elif [[ $what =~ ^[0-9a-f]{40}$ ]]; then target="\"commit\": \"$what\""
    elif [[ $what =~ ^[A-Za-z0-9._/-]+$ ]]; then target="\"branch\": \"$what\""
    else echo "publish: give master, a pull request number, a branch or a commit" >&2; exit 2; fi
    [[ $config =~ ^[a-z0-9_]+$ && $devices =~ ^(cpu|cuda|cpu,cuda)$ && $options =~ ^[A-Za-z0-9_.,=+(){}-]*$ && $sets =~ ^[a-z,]*$
       && $subset =~ ^[a-z0-9=+,-]*$ && $instances =~ ^[A-Za-z0-9_.+,-]*$ ]] ||
        { echo "publish: bad --config, --devices, --options, --sets, --subset or --instances" >&2; exit 2; }
    [[ $label =~ ^[A-Za-z0-9\ \#().+_-]{0,40}$ ]] ||
        { echo "publish: --label is up to 40 letters, digits, spaces and # ( ) . _ + -" >&2; exit 2; }
    [ -n "$note" ] || { echo "publish: give --note: what the job is for" >&2; exit 2; }
    [[ ${#note} -le 200 && $note != *[\"\\]* ]] || { echo "publish: --note is up to 200 characters, without \" or \\" >&2; exit 2; }
    list=""
    [ -n "$instances" ] && list=", \"instances\": [\"${instances//,/\",\"}\"]"
    body="{\"external\": true, $target, \"devices\": \"$devices\", \"config\": \"$config\", \"options\": \"$options\"${sets:+, \"sets\": \"$sets\"}${subset:+, \"subset\": \"$subset\"}$list, \"note\": \"$note\"${label:+, \"label\": \"$label\"}}"
    out=$(curl -sS -H @<(printf 'Authorization: Bearer %s\n' "$token") -H "Content-Type: application/json" --data-binary "$body" "$site/queue/api/jobs") ||
        { echo "publish: $site cannot be reached" >&2; exit 2; }
    id=$(json_field id <<< "$out") jtoken=$(json_field token <<< "$out")
    [[ $id =~ ^[0-9]+$ && -n $jtoken ]] || { echo "publish: the website refused: $out" >&2; exit 2; }
    problem=$(json_field error <<< "$out"); [ -n "$problem" ] && echo "publish: $problem" >&2
    jobfile=${jobfile:-$PWD/benchmark-job-$id}
    (umask 077; printf '%s %s %s\n' "$site" "$id" "$jtoken" > "$jobfile")
    n=$(json_field instances <<< "$out")
    echo "job $id: $(json_field sha <<< "$out"), $devices, $config${options:+, $options}${n:+, $n instances (${subset:-listed})}"
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
work=${work:-$PWD/benchmark-work/job$id-$(hostname -s)}
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
sets=$(json_field sets <<< "$spec") only=$(json_field only <<< "$spec")
islocal=$(json_field local <<< "$spec") changes=$(json_field changes <<< "$spec") pull=$(json_field pull <<< "$spec")
if [ "$islocal" = true ]; then
    # local code: this machine's checkout, which must be the job's
    [ -n "$madnlp" ] || { echo "publish: job $id is local code: give --madnlp=PATH, the checkout it was made of" >&2; exit 2; }
    [ "$(git -C "$madnlp" rev-parse HEAD 2>/dev/null)" = "$sha" ] && [ "$(local_changes "$madnlp")" = "$changes" ] ||
        { echo "publish: $madnlp is not the code of job $id (its commit $sha${changes:+ with its uncommitted changes})" >&2; exit 2; }
    madnlp=$(cd "$madnlp" && pwd)
fi
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
    [[ $out == *'"quarantined": true'* ]] && quarantined=1
    if [[ $out == *'"cancel": false'* || $out == *'"cancel": true'* ]]; then
        taken=1
        mv "$next" "$marker"
    else
        echo "publish: the website did not take the files: $(head -c 300 <<< "$out")"
    fi
    [[ $out == *'"cancel": true'* ]]
}

# a GPU node checks its GPUs before taking any instance: the driver starts (cuInit) and nearly all of
# each GPU's memory is free, as memory something else holds makes every solve fail. A node that is
# not fit leaves with EX_TEMPFAIL (75) and takes nothing, so that a batch script can start another.
if [[ $devices == *cuda* ]]; then
    fit=$(python3 - <<'PY' 2>&1
import ctypes, os, sys
try:
    cuda = ctypes.CDLL("libcuda.so.1")
except OSError as err:
    sys.exit(f"no CUDA driver: {err}")
if cuda.cuInit(0) != 0:
    sys.exit(f"cuInit failed: {cuda.cuInit(0)}")
n = ctypes.c_int()
cuda.cuDeviceGetCount(ctypes.byref(n))
for i in range(n.value):
    dev, ctx = ctypes.c_int(), ctypes.c_void_p()
    cuda.cuDeviceGet(ctypes.byref(dev), i)
    if cuda.cuDevicePrimaryCtxRetain(ctypes.byref(ctx), dev) != 0 or cuda.cuCtxSetCurrent(ctx) != 0:
        sys.exit(f"GPU {i}: no context")
    free, total = ctypes.c_size_t(), ctypes.c_size_t()
    cuda.cuMemGetInfo_v2(ctypes.byref(free), ctypes.byref(total))
    cuda.cuDevicePrimaryCtxRelease(dev)
    if free.value < 0.9 * total.value:
        sys.exit(f"GPU {i}: only {free.value / 2**30:.1f} of {total.value / 2**30:.1f} GB free")
print(f"{n.value} GPU(s) fit")
PY
    ) || { echo "publish: this node is not fit for GPU work: $fit; leaving"; send failed >/dev/null; exit 75; }
    echo "publish: $fit"
fi

# setting up takes from seconds to half an hour (cloning, installing, precompiling, or waiting for
# another node doing it): say so to the website meanwhile, with the log, so that the job's nodes and
# what they are doing show from the start
( while :; do send setup >/dev/null; sleep $(( every > 30 ? every : 30 )); done ) &
beat=$!
trap 'kill $beat 2>/dev/null; send interrupted; exit 143' TERM INT
setup_done() { kill $beat 2>/dev/null; wait $beat 2>/dev/null; }

# the last results of a node that is done: sent again while the website does not take them (it may
# be busy, a 502 from its proxy), as nothing is sent after them; still not taken, they stay in the
# work directory, and running the node again with it sends them
send_last() {   # state
    local i
    for i in 1 2 3 4 5 6; do
        taken=0
        send "$1" >/dev/null
        [ "$taken" = 1 ] && return 0
        echo "publish: the website did not take the last results; sending them again in $((20 * i)) s"
        sleep $((20 * i))
    done
    echo "publish: the last results could not be sent; they are in $work/results"
}

# the commit, set up with this harness, in a folder named by both: the same path on every node and
# in every later job, so that what Julia compiled for it is found again. The first node sets it up,
# under a lock; the others wait and use it.
export JULIA_DEPOT_PATH="$(readlink -f "$depot")"
version=$( (cd "$here" && git rev-parse --short=12 HEAD 2>/dev/null) || find "$here" -name '*.jl' -o -name '*.toml' | sort | xargs cat | sha1sum | cut -c1-12)
src=${src:-$work}
mkdir -p "$src"
tree=$(cd "$src" && pwd)/${sha:0:12}${changes:+-local-${changes:0:8}}-$version
# whether the tree is set up. On a network file system a node may keep "no such file" for a name it
# looked up before another node made it, and would then take the finished tree for a broken one and
# set it up again under the nodes using it; so the lock file says so too, which a node holding the
# lock reads afresh
ready() { grep -qx ready "$tree.lock" 2>/dev/null || ls -a "$tree" 2>/dev/null | grep -qx '.ready'; }
ready || echo "publish: setting up $tree (or waiting for the node that is)"
(
    flock 9 || exit 3
    if ! ready; then
        rm -rf "$tree" && mkdir -p "$tree" || exit 3
        if [ "$islocal" = true ]; then
            cp -a "$madnlp" "$tree/madnlp" || exit 3                   # as it is, uncommitted changes included
        else
            git clone -q https://github.com/madsuite-org/MadNLP.jl "$tree/madnlp" || exit 3
            # a pull request (a fork's too) by the ref GitHub keeps for it in MadNLP.jl
            [ -n "$pull" ] && { git -C "$tree/madnlp" fetch -q origin "+refs/pull/$pull/head:refs/remotes/origin/pull/$pull" || exit 3; }
            git -C "$tree/madnlp" checkout -q --detach "$sha" || exit 3
        fi
        cp -a "$here" "$tree/harness" && rm -rf "$tree/harness/.git" "$tree/harness/madnlp" "$tree/harness/.claude" "$tree/harness/results" || exit 3
        (cd "$tree/harness" && julia --startup-file=no setup.jl "$tree/madnlp" ${hsl:+--hsl=$hsl}) || exit 4
        touch "$tree/.ready" && echo ready >> "$tree.lock"
    fi
) 9>> "$tree.lock" || { setup_done; send failed; exit 4; }
cd "$tree/harness"
# Julia compiles packages for the processor it runs on, so nodes of different processors sharing a
# depot would keep recompiling over each other: each kind of processor has a depot of its own in
# front of the shared one, for what it compiles, and compiles once, one node at a time.
cpu=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1 | tr -c 'A-Za-z0-9\n' '_' | tr -s '_' | cut -c1-60)
# and a GPU job's has its own too: CUDA's packages compiled on a machine without a GPU driver (a CPU
# node of the same processor) record that there is none, and a GPU node loading them then finds no
# CUDA runtime
[ "$devices" = cpu ] || cpu="${cpu:-unknown}-gpu"
mkdir -p "$depot/by-cpu/${cpu:-unknown}"
export JULIA_DEPOT_PATH="$(readlink -f "$depot/by-cpu/${cpu:-unknown}"):$(readlink -f "$depot")"
echo "publish: precompiling for $cpu (or waiting for the node that is)"
(
    flock 9 || exit 3
    julia --startup-file=no --project=. -e 'using Pkg; Pkg.precompile()' || exit 4
) 9> "$depot/by-cpu/${cpu:-unknown}.lock" || { setup_done; send failed; exit 4; }
setup_done
export BENCHMARK_CLAIM=$api/claim BENCHMARK_AUTH=$auth BENCHMARK_NODE=$node
julia --startup-file=no --project=. run.jl "${sets:-acopf,cops,mittelmann,cutest}" --device="$devices" --config="$config" \
    ${options:+"--options=$options"} ${only:+"--only=$only"} --root="$work/results" < /dev/null &
bench=$!
# the ends of the logs being written, every 3 s, for the website to show them as they come: the
# solver logs written to in the last 15 s and this node's own log; results go with `send`
stream() {
    local s=$work/.stream
    rm -rf "$s" && mkdir -p "$s"
    (cd "$work/results" && find . -path '*/logs/*' -name '*.txt' -mmin -0.25 2>/dev/null | head -50) | while read -r f; do
        mkdir -p "$s/$(dirname "$f")" && tail -c 16000 "$work/results/$f" > "$s/$f"
    done
    tail -c 16000 "$log" > "$s/job.log"
    tar czf "$work/.stream.tar.gz" -C "$s" . 2>/dev/null &&
        curl -sS -m 10 -o /dev/null -H @"$auth" --data-binary @"$work/.stream.tar.gz" "$api/stream?node=$node" 2>/dev/null
}
( while kill -0 $bench 2>/dev/null; do stream; sleep 3; done ) &
streamer=$!
# stopped (killed, cancelled): say so, and keep what there is; running this again carries on
trap 'kill $streamer $bench 2>/dev/null; wait $bench; send interrupted; exit 143' TERM INT
while kill -0 $bench 2>/dev/null; do
    sleep "$every" & wait $!
    if kill -0 $bench 2>/dev/null && send running; then
        kill $streamer $bench 2>/dev/null; wait $bench
        # put aside by the website (machine failures in a row): leave with EX_TEMPFAIL, so that a
        # batch script can start another node elsewhere; its results are handed out again
        [ "${quarantined:-0}" = 1 ] && { echo "publish: the website put this node aside (machine failures); leaving"; exit 75; }
        echo "publish: job $id was cancelled"; send_last cancelled; exit 0
    fi
done
wait $bench; rc=$?
kill $streamer 2>/dev/null
if [ $rc -eq 0 ]; then send_last finished; else send_last failed; fi
echo "publish: node $node done ($rc), $(json_field report <<< "$spec")"
exit $rc
