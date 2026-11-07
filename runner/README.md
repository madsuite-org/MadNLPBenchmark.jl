# Runner

The benchmark machine's side of the run queue at https://benchmark.madsuite.org/queue (code in
[benchmark-report](https://github.com/madsuite-org/benchmark-report), `queue/`).

`runner.py` takes one job at a time by holding `GET /queue/runner/next` open, so the machine
accepts no connections. It runs as its own user and holds the runner's token, and never runs
benchmarked code. A job, `{id, kind, pr, sha, folder, keep}`, is run by `job.sh` as another user in
a unit of its own, started and stopped by root-owned wrappers allowed by sudo (`RUNNER_START`,
`RUNNER_STOP`), with `ci-preempt start` and `end` around it.

`job.sh` clones MadNLP.jl at the commit, checks it, links it into a copy of this harness, runs
`run.jl`, and every 5 s copies the results to the live folder of the website and replaces its
`run.json`. With `keep` it takes over the results already in that folder; with `fresh` it throws
them away first. Stopped, it copies what it has and marks the run cancelled.

    python3 -m unittest discover -s runner
