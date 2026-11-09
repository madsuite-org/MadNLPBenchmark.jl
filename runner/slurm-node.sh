#!/bin/bash
# One node of a benchmark job inside a Slurm batch job, which keeps the job supplied with nodes: when
# this node ends while the job still has work, it submits a node to take its place.
#
#     runner/slurm-node.sh [publish.sh run options...]      # from a batch script, see slurm-node.sbatch
#
# Give the batch script --requeue (a preempted node is requeued by Slurm itself, as the same node) and
# --signal=B:TERM@120 (a node near its time limit is told two minutes before). A node stopped at its
# time limit, or one that failed (out of memory, say), submits a replacement with the same batch
# script, options and work directory, so it carries on as the same node with what it had; at most
# BENCHMARK_GENERATIONS (5) in a row, so that a node that keeps failing does not go on for ever. A node
# that ends because the job is done or cancelled submits nothing. The options a node was submitted with
# reach its replacement through BENCHMARK_SBATCH (say "--partition=a,b --time=06:00:00"), which the
# first submission sets; the job file through JOB_FILE.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
: "${SLURM_JOB_ID:?run this inside a Slurm batch job}" "${JOB_FILE:?set JOB_FILE}"
work=${BENCHMARK_NODE_WORK:-${SLURM_SUBMIT_DIR:-$PWD}/benchmark-work/$(basename "$JOB_FILE")-$SLURM_JOB_ID}
generation=${BENCHMARK_GENERATION:-0}
script=$(scontrol show job "$SLURM_JOB_ID" | sed -n 's/^ *Command=\([^ ]*\).*/\1/p')

"$here/runner/publish.sh" run --job-file="$JOB_FILE" --work="$work" "$@" &
node=$!
trap 'kill -TERM $node 2>/dev/null' TERM INT
wait $node; rc=$?
while kill -0 $node 2>/dev/null; do wait $node; rc=$?; done   # a signal ends the first wait early

# the job is done or cancelled for this node: nothing to replace
[ $rc -eq 0 ] && exit 0
# stopped by a signal with time to spare: preemption, and Slurm requeues this node itself
left=$(squeue -h -j "$SLURM_JOB_ID" -o %L 2>/dev/null | awk -F'[-:]' '{s=0; for (i=1;i<=NF;i++) s=s*60+$i; if (NF==4) s=$1*86400+$2*3600+$3*60+$4; print s}')
if [ $rc -eq 143 ] && [ "${left:-0}" -gt 300 ]; then
    echo "node: stopped with ${left} s left, preempted: Slurm requeues it"
    exit $rc
fi
if [ "$generation" -ge "${BENCHMARK_GENERATIONS:-5}" ] || [ -z "$script" ]; then
    echo "node: ended ($rc), not replaced (generation $generation)"
    exit $rc
fi
echo "node: ended ($rc) with ${left:-?} s left; submitting a replacement (generation $((generation + 1)))"
# after this node has ended, since it shares the work directory; what it needs goes through the
# environment (--export=ALL), as BENCHMARK_SBATCH has commas, which --export cannot carry
export JOB_FILE BENCHMARK_NODE_WORK="$work" BENCHMARK_GENERATION=$((generation + 1))
# shellcheck disable=SC2086
sbatch ${BENCHMARK_SBATCH:-} --dependency=afterany:"$SLURM_JOB_ID" --export=ALL "$script"
exit $rc
