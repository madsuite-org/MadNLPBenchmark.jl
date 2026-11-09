#!/bin/bash
# One node of a benchmark job of benchmark.madsuite.org, as a Slurm batch job. Submit several:
#
#     sbatch --export=ALL,JOB_FILE=$PWD/benchmark-job-57 runner/slurm-node.sbatch
#
# Adjust the partition, the GPU (one kind of GPU for comparable times) and the paths. The nodes share
# one Julia depot and checkout. A preempted node is requeued and carries on; one stopped at its time
# limit or failing submits a replacement, which carries on as the same node (runner/slurm-node.sh).
#SBATCH --job-name=madnlp-node
#SBATCH --partition=mit_preemptable
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=1-00:00:00
#SBATCH --requeue
#SBATCH --signal=B:TERM@120
#SBATCH --open-mode=append
#SBATCH --output=%x-%j.out
set -u
here=${SLURM_SUBMIT_DIR:-$PWD}
# exec: slurm-node.sh becomes the batch shell, which the signal of --signal=B:... goes to
exec "$here/runner/slurm-node.sh" --depot="${BENCHMARK_DEPOT:-$here/benchmark-depot}" --src="${BENCHMARK_SRC:-$here/benchmark-src}" \
    ${BENCHMARK_HSL:+--hsl=$BENCHMARK_HSL}
