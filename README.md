# MadNLPBenchmark.jl

The baseline benchmark of [MadNLP.jl](https://github.com/madsuite-org/MadNLP.jl): it solves
standard problem sets with a chosen solver configuration, records every solve in a CSV file, and
archives the results of a commit for later comparison. Use it to measure a change to MadNLP, a new
KKT system, a new linear solver or a new option set against the current state of the solver.

It benchmarks a MadNLP checkout given from outside. `setup.jl` links that checkout as
`madnlp/`, from which `Project.toml` takes MadNLP, its core packages and cuMadNLP through
`[sources]`, and the results record its commit. The problem packages that are not registered are
pinned to a commit there, and the registered ones are bounded in `[compat]`, so that the instances
and the software around MadNLP are the same from one run to the next. Widening a bound or moving a
pin is a change to the benchmark itself. The MadNLP packages are bounded in `[compat]` to the series the harness is
written for, so that a checkout of another series fails at setup. The website at https://benchmark.madsuite.org/madnlp/ is
built from the results by [benchmark-report](https://github.com/madsuite-org/benchmark-report).

The code of an earlier version of this repository is on the `legacy` branch.

## Quick start

```sh
git clone https://github.com/madsuite-org/MadNLP.jl ../MadNLP.jl   # at the commit to benchmark
julia setup.jl ../MadNLP.jl                                         # [--hsl=PATH] for MA57

julia --project=. run.jl smoke                                      # a functional check
julia --project=. run.jl acopf,cops,mittelmann,cutest --device=cpu,cuda
julia --project=format format/archive.jl results --repo=../MadNLP.jl   # needs push access
```

## Problem sets

| set | instances | source |
|:---|---:|:---|
| `acopf` | 132 | the 66 typical-operating-point cases of pglib-opf, each in the polar and in the rectangular form, through ExaModelsPower |
| `cops` | 65 | the COPS problems of COPSBenchmark: nine scaling models at five sizes each, the other models at their canonical sizes |
| `mittelmann` | 47 | the instances scored in Hans Mittelmann's AMPL-NLP benchmark, through ExaMittelmann |
| `cutest` | 1338 | the CUTEst problems with at least as many free variables as equality constraints (`sets/cutest.txt`): through CUTEst.jl on the host, as ExaCUTEst models on a device |
| `smoke` | 12 | small ACOPF and COPS instances, for a functional check |

The sets are defined in `sets.jl`. Every set runs on the host and on a CUDA device.

## Configurations

A configuration is a named set of keyword arguments of `madnlp`: a KKT system, a linear
solver and their options. They are defined in `configs.jl`; add an entry there to benchmark
something new.

| configuration | device | KKT system | linear solver |
|:---|:---|:---|:---|
| `default` | cpu | MadNLP's default (`SparseKKTSystem`) | MA57 with automatic scaling with a licensed HSL_jll, else MUMPS |
| `augmented_mumps` | cpu | `SparseKKTSystem` | MUMPS |
| `ipopt` | cpu | Ipopt's own | MA57 with automatic scaling with a licensed HSL_jll, else MUMPS, as a baseline; no time breakdown or factorization counts |
| `condensed_cholmod` | cpu | `SparseCondensedKKTSystem` | CHOLMOD |
| `augmented_ma27`, `augmented_ma57` | cpu | `SparseKKTSystem` | MA27, MA57 with automatic scaling; only with a licensed HSL_jll |
| `default` | cuda | cuMadNLP's default (`SparseCondensedKKTSystem`) | cuDSS |
| `augmented_cudss` | cuda | `SparseKKTSystem` | cuDSS with Bunch-Kaufman pivoting |

## Options of `run.jl`

| option | default | meaning |
|:---|:---|:---|
| `--config=a,b` | `default` | the configurations to run |
| `--device=cpu\|cuda\|cpu,cuda` | `cpu` | where the models and the solver live; `cpu,cuda` runs both side by side, each with its own result directory |
| `--workers=auto\|N` | `auto` | the number of processes that solve; see below |
| `--root=DIR` | `results` | where the per-machine result directories go |
| `--out=DIR` | `<root>/<hardware>` | where the result files go; `<hardware>` is the CPU model or the GPU name |
| `--only=case,...` | all | restrict a set to the named instances |
| `--tol=1e-8` | `1e-8` | convergence tolerance, and the acceptable tolerance |
| `--wall=1800` | `1800` | wall limit of a solve on the host, in seconds |
| `--cuda-wall=1800` | `1800` | the same on a CUDA device |
| `--margin=S` | larger of 120 s and 20% of the limit | how far past the limit a worker is killed |
| `--status-every=600` | `600` | seconds between status reports |
| `--options=a=1,b=x` | | MadNLP options on top of `default`, run as configuration `custom-<hash>` (see below) |
| `--no-warmup` | | skip the discarded solves (see the protocol) |
| `--overwrite` | | start the result files afresh instead of resuming |
| `--verbose` | | print MadNLP's iteration log |

A run that is interrupted is resumed by the same command: an instance already in a result
file is skipped.

**Workers.** The instances of all the requested sets form one queue, handed out to worker
processes. On a CUDA device there are two workers per GPU (`--workers-per-gpu`), of which one solves at a time while the other builds its next model. On the host,
`auto` follows what the process may use, a batch job's allocation included: 75% of the physical
cores, limited to 3 GB per worker out of 75% of the memory. Workers that run side by side on the host share its
memory channels and slow each other down somewhat, so use `--workers=1` for the cleanest host
timings. Each worker has a heap-size hint of 6 GB and is replaced between cases if it grows
past 8 GB. The number of workers is recorded in the metadata.

**Wall limit.** MadNLP checks `max_wall_time` between iterations, so one long factorization
or evaluation can overrun it. The coordinating process therefore kills a worker when a build
or a solve has run for the wall limit plus a margin (`--margin`, by default the larger of
120 s and 20% of the limit), records the instance with status `-100`, and starts a new worker. A worker that passes 40% of
the machine's memory during a solve is treated the same way.

**Log.** Everything a run prints, package compilation and worker output included, also goes to
`run.log` in the result root as it is printed.

**Status.** Every ten minutes the log gives the instances done and, per worker, the instance,
its state (`building`, `waiting` for a GPU, `solving`, `working`) and for how long, longest
first, with its memory, followed by the solved counts and mean times so far. The same report
is kept in `summary.md` beside the result files, rewritten every 5 s. It also appears in the log.

**CUTEst.** On the host one more process decodes the problems, one after the other, while the
workers solve the sets ahead of CUTEst, so list `cutest` last. The decoded files stay in
CUTEst.jl's directory for later runs.

**Options.** `--options` takes `name=value` pairs, separated by commas, and runs them on top of
the `default` configuration of the device. Values are read, never evaluated, and are never quoted:
an integer, a float, `true` or `false`; a name MadNLP defines, a type or a value (`SparseKKTSystem`,
`CHOLMODSolver`, `KrylovIterator`, `LDL`); a call to a type of MadNLP with values as arguments,
which constructs it (`RuizScaler()`, `QualityFunctionUpdate{Float64}(sigma_max=2,mu_min=1e-11)`);
or a bare word of letters, digits, `_`, `.` and `-` for an option whose declared type is a string,
a character or a symbol. Commas inside parentheses belong to the call. For example, MadNLP's GPU
preset on the host:

    --options=kkt_system=SparseKKTSystem,linear_solver=CHOLMODSolver,cholmod_algorithm=LDL,cholmod_dbound=1e-10,kkt_scaler=RuizScaler(),dual_shift=1e-10,iterator=KrylovIterator,barrier=QualityFunctionUpdate{Float64}(sigma_max=2,mu_min=1e-11),slack_reset=true

Unknown option names are refused, and
so are the options that name files. The results go under the configuration
`custom-<8 hex digits>`, from the options in sorted order, and the metadata records them as
`custom_options`. `configs.toml` lists the configuration names per device, the option names and
the values allowed, for checking a job without Julia; `configs_toml.jl` rewrites it and checks
that it is up to date.

## Protocol

- **Options.** MadNLP's defaults, apart from what the configuration sets, the tolerance, which
  is also the acceptable tolerance, and the wall limit. A configuration that tunes other options says so in `configs.jl`.
- **Wall limit:** 1800 s per solve, on the host and on a GPU, for every solver (since benchmark 0.4.0;
  before, 1800 s on the host and 600 s on a GPU from 0.3.0, and 7200 s on the host). The website holds
  older results to the same limit, or to their own if lower.
- **Solved.** An instance is solved if MadNLP returns `SOLVE_SUCCEEDED` or
  `SOLVED_TO_ACCEPTABLE_LEVEL`. Every other exit, including the iteration limit with a good
  last iterate, is a failure.
- **Time.** The recorded time is MadNLP's total time of one solve, with the initialization,
  the linear solver and the function evaluations also recorded separately.
- **Compilation.** No recorded solve includes compilation. The callbacks of an ExaModel are
  compiled after the model is built, outside the timed region. Instances of one COPS model go
  to one worker, so that they are compiled once. Julia's compilation time is then measured
  around every solve, and a solve during which Julia compiled is repeated; an
  instance is also solved a second time when its model type is new to the configuration in
  that process, because the kernels of a device are compiled outside Julia's timer. The
  column `t_compile` is the compilation time of the recorded solve and `n_solves` the number
  of solves it took. A solve that reaches the wall limit is recorded as it is.
- **Aggregate.** The number of instances solved, and the shifted geometric mean of the solve
  time with a shift of 10 s, a failure counting as the wall limit. Instances are split into
  small, medium and large by the nonzeros of the Jacobian and the Hessian together: below
  2^18, below 2^20, and above.
- **Feasibility.** `primal_feas` is the residual of the solver's scaled, relaxed problem. The
  columns `viol_eq`, `viol_con` and `viol_var` are the violation of the model's own constraints and
  bounds at the returned point, evaluated independently of the solver.
- **Hardware.** Timings are comparable only on the same machine. Each result file has a
  metadata file beside it (`.meta.toml`) with the host, the CPU model, its cores and threads,
  the memory, the GPU with its memory, driver and CUDA runtime, the thread counts, the package
  versions, the MadNLP commit and the options. The report names the machines.

## Result files

`run.jl` writes `<set>_<configuration>.csv` with one row per instance:

`case, status, iters, nvar, ncon, nnzj, nnzh, obj, primal_feas, dual_feas, n_fact,
n_backsolve, n_ir, n_obj, n_grad, n_con, n_jac, n_hess, t_total, t_linsolve, t_eval, t_init,
t_compile, n_solves, viol_eq, viol_con, viol_var`

`status` is MadNLP's status code; `-100` marks an instance whose worker was killed at the wall
limit, and `-101` one whose model could not be built or whose solve threw.

## Results and archive

Solver logs are in `logs/<set>/<instance>__<configuration>.txt` beside the result files.
`format` is a small package with no solver among its dependencies: it reads and
scores result files, and its `archive.jl` archives them. The website at
https://benchmark.madsuite.org/madnlp/ is built from them by
[benchmark-report](https://github.com/madsuite-org/benchmark-report), which can also be run by
hand.

Results are archived on the `benchmark-results` branch of MadNLP.jl (`--repo`), under `<hardware>/<commit>/`, with the
metadata files and a summary. `archive.jl [DIR]` archives result files under the commit recorded
in their metadata; with `--complete`, only the sets that are finished on a device, marked by a
`.complete` file beside their results, so that a run can be archived set by set while it goes
on. Timings are comparable only on the same machine.

**Ipopt reference.** Each version of this benchmark (`version` in `Project.toml`) has one Ipopt run,
`ipopt/<version>/` on the same branch, and every report shows it as the reference, with a scaled
mean of 1. The version fixes Ipopt (`Ipopt_jll` in `[compat]`) and the licensed HSL (`[benchmark]`
in `Project.toml`, which `run.jl` checks), so bump it when the instances, the pins, these
libraries or the protocol change, and run Ipopt once for the new version: `run.jl ... --config=ipopt`,
then `archive.jl DIR --ipopt-reference`.

## Running on your own machines (clusters included)

A benchmark runs on machines its creator provides: a workstation, a rented GPU, or nodes of a
cluster; the website runs none itself. Any member of madsuite-org, and anyone with write access to
MadNLP.jl, can create a job. The website hands out the instances, collects the results and builds
the job's run page; runs are compared in reports, made on the website. How the website works (who
can use it, runs and reports, its API) is on the website:
[How it works](https://benchmark.madsuite.org/queue/help). Two steps:

1. **Create a job, once.** This fixes what is run: the revision of MadNLP.jl and the configuration,
   options, devices and instances. It needs a GitHub token of a member of madsuite-org or of
   someone with write access to MadNLP.jl (`gh auth login`, or `BENCHMARK_TOKEN`), and writes a
   *job file* holding the job's number and its own token.

   ```sh
   runner/publish.sh new master --note="tolerance 1e-6 on GPU" --devices=cuda --options=tol=1e-6 --sets=acopf,cops
   # job 57: <commit>, cuda, default, tol=1e-6
   # report: https://benchmark.madsuite.org/madnlp/run-x57-<commit>/
   # job file: ./benchmark-job-57
   ```

   The revision is `master`, a pull request number, a branch, or a commit of madsuite-org/MadNLP.jl
   (no fork), resolved to a commit when the job is made. `--devices` is `cpu`, `cuda` or
   `cpu,cuda`; create CPU and GPU as two jobs, so that each can go where its hardware is.
   `--options=name=value,...` are MadNLP options on top of the default configuration (types,
   enums and calls such as `RuizScaler()` included). `--note` says what the job is for, `--label`
   names its column in reports. The instances: `--sets=acopf,cops,...`, and `--subset=TERMS`, all of
   which an instance meets, joined by commas: `size=small+medium+large`, `constrained=yes|no`,
   `failed=SOURCE`, `solved=SOURCE`, `resto=SOURCE` (a source being `ipopt` or a run such as
   `run-x50-1b00be2e`), and `suspects`, what the best configurations tend to fail; or a list,
   `--instances=a,b,...` or `--instances=@FILE`.

2. **Run it on as many machines as you like**, at once or later, with only the job file:

   ```sh
   runner/publish.sh run --job-file=benchmark-job-57 [--hsl=PATH] [--depot=DIR] [--src=DIR] [--work=DIR]
   ```

   Each machine (a *node*) takes the job's settings from the website, sets up that commit, and before
   each instance asks the website whether it is still to do, so no two nodes solve the same one.
   Every few seconds (`--every`, 5 by default) it sends what changed: result rows, its workers'
   status and its log, and every 3 seconds the ends of the logs it is writing. The run's page
   updates as they arrive, and its workers page shows each node and what it is solving: a node's
   log, and an instance's solver log, as they are written. An instance that failed for a machine
   reason (killed, or the worker crashed) is handed out again, twice at most, to another node.

Without a checkout, `curl -fsSL https://benchmark.madsuite.org/queue/run.sh | bash -s -- new ...` and
`... | bash -s -- run --job-file=...` do the same.

### Several machines on one job

1. Create one job per device, with a `--note` that says what it is for (it is shown with the
   report). Keep the job file private (it is mode 600): it lets anyone holding it add results to
   the job.
2. Start `runner/publish.sh run` on several **small** machines rather than one large one: the
   website spreads the instances over whichever have started, and more of them mean more
   throughput.
3. A node uses what it is given: on the host, `run.jl` starts workers for 75% of the cores it may
   use; on a GPU, 2 workers per GPU it sees.
4. For times you mean to compare, use one kind of GPU and one kind of CPU. Nodes of different kinds
   still give valid solves and iteration counts; the report shows the machine of each instance and
   marks times that come from different machines.
5. A node can be stopped at any time. Started again with the same work directory it is the same
   node and carries on; the instances a stopped node held go to the others after 10 minutes.
6. On a shared file system, give all nodes one `--depot` and one `--src`, and keep them between
   jobs: the first node of a commit sets it up and compiles it there while the others wait, and
   every other node, and every later job of that commit, reuses it.
7. Follow the job on the website's dashboard, or with the API: `GET /queue/api/jobs/<number>` (with
   a GitHub token) gives its state and nodes. Cancelling it there stops every node at its next
   request. The job ends when every node still running has finished.

The licensed HSL (`--hsl`, for MA57 on the host) is not public; without it the host uses MUMPS, and
the run's page says which.

### Uploading results by hand

An archive of results made any other way can be uploaded too:

```sh
julia setup.jl ../MadNLP.jl
julia --project=. run.jl acopf,cops --device=cuda --root=results
tar czf results.tar.gz -C results .
curl -H "Authorization: Bearer $(gh auth token)" --data-binary @results.tar.gz \
     "https://benchmark.madsuite.org/queue/api/results?name=my-experiment"
```

The answer gives the report's address. The name is lowercase letters, digits and `-`; sending the
same name again replaces your own upload. An upload is a run of its own. [How it works](https://benchmark.madsuite.org/queue/help) on the
website has the rest.
