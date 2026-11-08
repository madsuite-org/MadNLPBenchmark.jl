#!/bin/bash
# One node of a benchmark job of benchmark.madsuite.org, as a Slurm batch job. Submit several:
#
#     sbatch --export=ALL,JOB_FILE=$PWD/benchmark-job-57 runner/slurm-node.sbatch
#
# Adjust the partition, the GPU (one kind of GPU for comparable times) and the paths. A preempted
# node is requeued and carries on; the nodes share one Julia depot.
#SBATCH --job-name=madnlp-node
#SBATCH --partition=mit_preemptable
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=1-00:00:00
#SBATCH --requeue
#SBATCH --open-mode=append
#SBATCH --output=%x-%j.out
set -eu
here=${SLURM_SUBMIT_DIR:-$PWD}
exec "$here/runner/publish.sh" run --job-file="${JOB_FILE:?set JOB_FILE}" \
    --depot="${BENCHMARK_DEPOT:-$here/benchmark-depot}" --src="${BENCHMARK_SRC:-$here/benchmark-src}" --work="$here/benchmark-work/$(basename "$JOB_FILE")-$SLURM_JOB_ID" \
    ${BENCHMARK_HSL:+--hsl=$BENCHMARK_HSL}
