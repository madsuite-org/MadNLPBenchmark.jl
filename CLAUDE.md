# Working on MadNLPBenchmark.jl as an agent

This repository is the benchmark of MadNLP.jl. Read `README.md` for the problem sets, the
configurations, the options of `run.jl`, the protocol and the result files; this file is about how
to use it well: how to run a benchmark, how to read it, and how its results are kept.

## Run benchmarks through the queue, not on your own machine

The benchmark server at https://benchmark.madsuite.org runs one job at a time on one dedicated
machine, and publishes a report for every job at `/madnlp/<name>/`. Its timings are comparable
from one job to the next; timings from a shared development machine are not. Use the queue for
any number that will be reported. The API is documented in
[benchmark-report/queue/README.md](https://github.com/madsuite-org/benchmark-report/blob/main/queue/README.md).

Every request needs a GitHub token of someone with write access to MadNLP.jl:

```sh
API=https://benchmark.madsuite.org/queue/api
AUTH="Authorization: Bearer $(gh auth token)"
curl -s -H "$AUTH" $API/me                                   # can you run jobs?
curl -s -H "$AUTH" $API/jobs                                 # what is running and waiting
```

Queue a job:

```sh
# a pull request of MadNLP.jl, at its head when the job starts
curl -s -H "$AUTH" -H "Content-Type: application/json" -d '{"pr": 705}' $API/jobs
# a branch of MadNLP.jl
curl -s -H "$AUTH" -H "Content-Type: application/json" -d '{"branch": "my-branch"}' $API/jobs
# an experiment: extra MadNLP options, on both devices, in one job
curl -s -H "$AUTH" -H "Content-Type: application/json" \
     -d '{"branch": "master", "options": "kkt_scaler=RuizScaler,dual_shift=1e-10", "devices": "cpu,cuda"}' $API/jobs
```

- **One job per experiment.** Ask for both devices with `"devices": "cpu,cuda"` instead of
  queueing one job per device; the job runs them side by side.
- **Read the job back.** The answer echoes `config`, `options`, `harness` and `devices`. If a
  field you sent is missing from it, it was not applied: cancel the job rather than let it run as
  something else.
- **A job with non-default settings gets a report of its own**, compared with master on the same
  machine and never mixed with the standard runs.
- **Watch the start.** A job that fails does so in its first minutes (setup, a missing package, an
  unknown option). Check its state (`GET /jobs/<id>`) and its log on the job page
  (`/queue/job/<id>`) a few minutes after it starts, and again when it ends. Do not poll in a loop.
- **Cancel only your own jobs**, with `POST /jobs/<id>/cancel`, and read the state back: a cancel
  takes effect when the job stops.
- Jobs run in order, master first. Check the queue before adding a job behind a long one.

## Experiments that need code the harness does not have

Prefer `options`: any option of `madnlp` whose value is a literal or a name in `OPTION_VALUES`
(`configs.jl`) works without a change to the harness.

When an experiment needs code (a new linear solver, a new option value), put it on a branch of
this repository and queue it with `"harness": "<branch>"`. On that branch:

- Load new code from both `session.jl` (the run) and `configs_toml.jl` (the static listing).
- Add any new option value to `OPTION_VALUES`, then rewrite the listing with
  `julia --project=. configs_toml.jl --write` and commit `configs.toml`. The queue checks a job's
  options against `configs.toml` without Julia, so a stale listing refuses the job.
- Keep the branch based on the current `main`.

## Before you commit

- **Never commit a `Project.toml` rewritten by `setup.jl`.** `setup.jl` points `[sources]` at your
  local checkout. The committed file takes MadNLP's packages from `madnlp/<package>` and HSL_jll
  from the registry, with no absolute or machine-specific path. Check `git diff Project.toml`
  before every commit; a wrong `[sources]` makes every job fail at setup.
- Commit with a pathspec (`git commit -- <paths>`), so that unrelated local changes stay out.
- `main` is protected. A change reaches it through a pull request, and only with the maintainer's
  approval; the same holds for opening issues and pull requests.

## Running locally

Run locally only to check that something works (`run.jl smoke`) or to diagnose a failure, not to
produce reported numbers.

- **Use a fresh `--root` for every experiment, or `--overwrite`.** A run resumes: an instance
  already in a result file is skipped, including one that failed. A run after a code change,
  in an old root, reports the old results.
- Give each device its own `--root` when you run them as separate processes; a root has one
  `run.log`.
- Size `--workers` to the machine and to the other work on it.
- On a cluster, run everything as a batch job. Never run Julia on a login node.
- Write down the hardware, the MadNLP commit and the options of every number you quote; the
  metadata file beside each result file has them.

## Reading a report

- An instance is solved when MadNLP returns `SOLVE_SUCCEEDED` or `SOLVED_TO_ACCEPTABLE_LEVEL`.
  `-100` is a solve killed at the wall limit, `-101` a model that could not be built or a solve
  that threw.
- The aggregate is the number solved and the shifted geometric mean of the time (shift 10 s, a
  failure counting as the wall limit), over the instances that every solver shown has run. While
  a job runs, the report covers only the instances done so far: say how many when you quote it.
- Compare times only between runs on the same machine.
- Before calling something a regression, look at the same instance under master on the same
  machine: some instances fail for every configuration. The solver log of each instance is linked
  from its status in the report.
- When you quote a result, link the report and name the machine, the configuration and the number
  of instances.

## Where results are kept

- **The live reports** are built from each job's results as they arrive, and every pull request
  and experiment report is kept on the site.
- **The archive** is the `benchmark-results` branch of MadNLP.jl, under `<hardware>/<commit>/`,
  with the metadata and a summary. Runs of master through the queue are archived by the runner
  (`runner/archive.sh`), set by set as each set finishes.
- **Archiving by hand** (results run elsewhere that should be kept):

  ```sh
  julia --project=format format/archive.jl results --repo=../MadNLP.jl --dry-run   # look first
  julia --project=format format/archive.jl results --repo=../MadNLP.jl --note="what and where"
  ```

  It takes the commit from the metadata, refuses results from several commits, and with
  `--complete` archives only finished sets. It pushes to MadNLP.jl, so it needs push access and,
  like any push to that repository, the maintainer's approval.
- **The Ipopt reference** is one Ipopt run per version of this benchmark, under
  `ipopt/<version>/` on the same branch. Bump `version` in `Project.toml` when the instances, the
  pins, Ipopt, HSL or the protocol change, and run Ipopt once for the new version
  (`run.jl ... --config=ipopt`, then `archive.jl DIR --ipopt-reference`).
- **Results run elsewhere** (a cluster, a rented machine) can be shown on the site without
  archiving them, as a report of their own:

  ```sh
  tar czf results.tar.gz -C results .
  curl -H "$AUTH" --data-binary @results.tar.gz "$API/results?name=my-experiment"
  ```

## Lessons from past runs

Each rule above was learned the hard way. These are the stories behind some of them.

**The job that ran something else.** An experiment was queued with `options`, `harness` and
`devices`, and the server accepted it. Its answer, though, showed a plain run of `master`: the
server of that day did not know the new fields and ignored them silently. Reading the job back
caught it before hours of machine time went to the wrong benchmark. Read the answer of every
request you send.

**The commit that broke every job.** A branch was committed after a local `setup.jl`, with
`[sources]` pointing at a worktree on one machine and HSL_jll at a path in one home directory. It
merged, and from then on every job failed at setup on the server, where those paths do not exist.
The fix was one file; finding it took a cancelled run and an afternoon. Look at
`git diff Project.toml` before you commit.

**The rerun that changed nothing.** A failed experiment was fixed and run again into the same
`--root`. The run finished in seconds and reported the same failures: every instance was already
in the result file, failures included, so nothing was solved again. Use a fresh root, or
`--overwrite`.

**The benchmark that measured the wrong solver.** An experiment with GMRES refinement took
thousands of iterations on a GPU where the same method had solved in thirty on the CPU. The
algorithm was not at fault: MadNLP's cuDSS wrapper disabled matching, and the solve of the
indefinite matrix had a backward error near 1e-5. Richardson refinement had hidden this for months,
because it corrects an inaccurate solve with more steps; GMRES could not. When a result does not
match what the method should do, measure the pieces (here, `‖Ax − b‖` of one solve against cuDSS
called directly) before you change the method.

**The failure that was not new.** Rectangular-form ACOPF cases failed in a new configuration, and
looked like a regression. Master's archived run on the same machine failed them too, and so did
every pivoting choice on the CPU. Compare with master on the same machine before you call
something a regression.
