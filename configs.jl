# The solver configurations. `configs(device)` returns `name => options`, the keyword
# arguments that select the configuration in `madnlp(model; options...)`. Add an entry here
# to benchmark another KKT system, linear solver or option set. Included by run.jl after the
# solver packages are loaded.

# The option set of the condensed KKT system on the host; on a CUDA device cuMadNLP selects it.
const CONDENSED = (;
    kkt_system = MadNLP.SparseCondensedKKTSystem,
    equality_treatment = MadNLP.RelaxEquality,
    fixed_variable_treatment = MadNLP.RelaxBound,
    dual_initialization_method = MadNLP.DualInitializeSetZero,
)

# The augmented system factorized after Ruiz scaling and a dual shift, with small pivots bounded,
# and refined by GMRES on the unshifted system: CHOLMOD's LDL' on the host, cuDSS on a CUDA device
# (cuMadNLP's own options for this system: LDL', matching, deferred analysis).
const SHIFTED = (;
    kkt_system = MadNLP.SparseKKTSystem, kkt_scaler = MadNLP.RuizScaler(), dual_shift = 1.0e-10,
    iterator = MadNLP.KrylovIterator,
)
const SHIFTED_CPU = (; SHIFTED..., linear_solver = MadNLP.CHOLMODSolver, cholmod_algorithm = MadNLP.LDL, cholmod_dbound = 1.0e-10)
const SHIFTED_CUDA = SHIFTED
# The same with the quality-function (adaptive) barrier, its increases of mu capped at a factor of 2,
# and the slacks moved onto the constraints after an accepted step when every row holds
const ADAPTIVE = (; barrier = MadNLP.QualityFunctionUpdate{Float64}(sigma_max = 2.0, mu_min = 1.0e-11), slack_reset = true)

# Ipopt as a baseline, with its default MUMPS. Returns the fields of MadNLP's statistics that a
# result row reads, so that it goes through the same loop. Ipopt reports no time breakdown,
# factorization count or refinement count.
const IPOPT_STATUS = Dict(
    :first_order => MadNLP.SOLVE_SUCCEEDED, :acceptable => MadNLP.SOLVED_TO_ACCEPTABLE_LEVEL,
    :small_step => MadNLP.SEARCH_DIRECTION_BECOMES_TOO_SMALL, :infeasible => MadNLP.INFEASIBLE_PROBLEM_DETECTED,
    :max_iter => MadNLP.MAXIMUM_ITERATIONS_EXCEEDED, :max_time => MadNLP.MAXIMUM_WALLTIME_EXCEEDED,
)
# The evaluation counts Ipopt prints at the end of its log; the counters of an ExaModel do not
# record them. `nothing` without a log.
function ipopt_counts(path)
    (isempty(path) || !isfile(path)) && return nothing
    text = read(path, String)
    count_of(what) = (m = match(Regex("Number of $what evaluations\\s*=\\s*(\\d+)"), text); m === nothing ? 0 : parse(Int, m[1]))
    return (;
        obj_cnt = count_of("objective function"), obj_grad_cnt = count_of("objective gradient"),
        # Ipopt counts one evaluation of the constraints under both of its kinds
        con_cnt = max(count_of("equality constraint"), count_of("inequality constraint")),
        con_jac_cnt = max(count_of("equality constraint Jacobian"), count_of("inequality constraint Jacobian")),
        lag_hess_cnt = count_of("Lagrangian Hessian"),
    )
end

function run_ipopt(m; tol, acceptable_tol, max_wall_time, output_file = "", _...)
    NLPModels.reset!(m)
    solver = HSL.LIBHSL_isfunctional() ?
        (; linear_solver = "ma57", hsllib = HSL.HSL_jll.libhsl_path, ma57_automatic_scaling = "yes") : (;)
    log = isempty(output_file) ? (;) : (; output_file, file_print_level = 5)
    # MadNLP stops at the acceptable level on its scaled error alone, and here acceptable_tol is tol,
    # so its acceptable exit is no looser than its converged one. Ipopt's acceptable exit also has
    # its own limits on the unscaled violations, looser by default (constraints and complementarity
    # 1e-2, dual 1e10); they are set to those of its converged exit, so that it is no looser either.
    acceptable = (; acceptable_constr_viol_tol = 1e-4, acceptable_dual_inf_tol = 1.0, acceptable_compl_inf_tol = 1e-4)
    s = NLPModelsIpopt.ipopt(m; tol, acceptable_tol, max_wall_time, print_level = 0, acceptable..., solver..., log...)
    logged = ipopt_counts(output_file)
    counters = (;
        factorization_cnt = 0, backsolve_cnt = 0, ir = 0, obj_cnt = NLPModels.neval_obj(m), obj_grad_cnt = NLPModels.neval_grad(m),
        con_cnt = NLPModels.neval_cons(m), con_jac_cnt = NLPModels.neval_jac(m), lag_hess_cnt = NLPModels.neval_hess(m),
        total_time = s.elapsed_time, linear_solver_time = NaN, eval_function_time = NaN, init_time = NaN,
        something(logged, (;))...,
    )
    return (;
        status = get(IPOPT_STATUS, s.status, MadNLP.ERROR_IN_STEP_COMPUTATION), iter = s.iter, objective = s.objective,
        primal_feas = s.primal_feas, dual_feas = s.dual_feas, solution = s.solution, counters,
    )
end

function configs(device::Symbol; hsl::Bool = HSL.LIBHSL_isfunctional())
    c = Pair{String, NamedTuple}[]
    # The augmented system with MA57 on the host where a licensed HSL_jll is installed, else with
    # MUMPS, and the condensed system with cuDSS on a CUDA device
    ma57 = (; linear_solver = MadNLP.Ma57Solver, ma57_automatic_scaling = true)
    push!(c, "default" => (device == :cpu && hsl ? ma57 : (;)))
    if device == :cpu
        push!(c, "augmented_mumps" => (; linear_solver = MadNLP.MumpsSolver))
        push!(c, "ipopt" => (; solver = run_ipopt))
        push!(c, "condensed_cholmod" => (; CONDENSED..., linear_solver = MadNLP.CHOLMODSolver))
        push!(c, "shifted" => SHIFTED_CPU)
        push!(c, "shifted_qf" => (; SHIFTED_CPU..., ADAPTIVE...))
        if hsl   # the registry's HSL_jll carries no solver
            push!(c, "augmented_ma27" => (; linear_solver = MadNLP.Ma27Solver))
            push!(c, "augmented_ma57" => ma57)
        end
    elseif device == :cuda
        # Bunch-Kaufman pivoting needs cuDSS's matching, which reads the matrix values: the
        # analysis runs at the first factorization, the factorization re-pivots at every
        # iteration, and a solve rejected by iterative refinement redoes the analysis
        push!(
            c, "augmented_cudss" => (;
                kkt_system = MadNLP.SparseKKTSystem, linear_solver = cuMadNLP.CUDSSSolver,
                cudss_pivoting = true, cudss_pivot_type = 'B', cudss_matching = true, cudss_matching_alg = "algo6",
                cudss_deferred_analysis = true, cudss_refactorization = false, cudss_reanalyze_on_improve = true,
            ),
        )
        push!(c, "shifted" => SHIFTED_CUDA)
        push!(c, "shifted_qf" => (; SHIFTED_CUDA..., ADAPTIVE...))
    end
    # options from the command line, on top of the default configuration
    isdefined(Main, :CUSTOM_OPTIONS) && !isempty(Main.CUSTOM_OPTIONS) &&
        push!(c, custom_name(Main.CUSTOM_OPTIONS) => custom_options(last(c[1]), parse_options(Main.CUSTOM_OPTIONS)))
    return c
end

# MadNLP ignores an option it does not know, so a mistyped option would measure the default
# under the name of the configuration.
# Options given as text, `name=value,...`, as from `run.jl --options`. Only literals are read,
# never evaluated, and no value is quoted: an integer, a float, `true` or `false`, a name in
# OPTION_VALUES, or a bare word (letters, digits, `_`, `.`, `-`) for an option whose declared type
# is a string or a character. Options that name files are refused, since the benchmark sets them.
const OPTION_VALUES = Dict{String, Function}(
    "SparseKKTSystem" => () -> MadNLP.SparseKKTSystem, "SparseCondensedKKTSystem" => () -> MadNLP.SparseCondensedKKTSystem,
    "SparseUnreducedKKTSystem" => () -> MadNLP.SparseUnreducedKKTSystem,
    "MumpsSolver" => () -> MadNLP.MumpsSolver, "CHOLMODSolver" => () -> MadNLP.CHOLMODSolver,
    "Ma27Solver" => () -> MadNLP.Ma27Solver, "Ma57Solver" => () -> MadNLP.Ma57Solver,
    "CUDSSSolver" => () -> cuMadNLP.CUDSSSolver,
    "RelaxEquality" => () -> MadNLP.RelaxEquality, "EnforceEquality" => () -> MadNLP.EnforceEquality,
    "RelaxBound" => () -> MadNLP.RelaxBound, "MakeParameter" => () -> MadNLP.MakeParameter,
    "DualInitializeSetZero" => () -> MadNLP.DualInitializeSetZero,
    "DualInitializeLeastSquares" => () -> MadNLP.DualInitializeLeastSquares,
    "LDL" => () -> MadNLP.LDL, "CHOLESKY" => () -> MadNLP.CHOLESKY, "LU" => () -> MadNLP.LU,
)
const REFUSED_OPTIONS = (:output_file,)

# The declared type of an option, from MadNLP's options or those of a linear solver it lists.
function option_type(name::Symbol)
    hasfield(MadNLP.MadNLPOptions{Float64}, name) && return fieldtype(MadNLP.MadNLPOptions{Float64}, name)
    for value in values(OPTION_VALUES)
        type = try
            value()
        catch   # a solver of a package this process has not loaded, such as cuMadNLP on the host
            continue
        end
        type isa Type && hasmethod(MadNLP.default_options, Tuple{Type{type}}) || continue
        options = typeof(MadNLP.default_options(type))
        hasfield(options, name) && return fieldtype(options, name)
    end
    return Nothing
end

function option_value(name::Symbol, text)
    occursin(r"^-?[0-9]+$", text) && return parse(Int, text)
    occursin(r"^-?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$", text) && return parse(Float64, text)
    text in ("true", "false") && return text == "true"
    haskey(OPTION_VALUES, text) && return OPTION_VALUES[text]()
    if occursin(r"^[A-Za-z0-9_.-]+$", text)
        type = option_type(name)
        type <: AbstractString && return String(text)
        type <: AbstractChar && length(text) == 1 && return only(text)
    end
    return error("option $name=$text: not a number, a boolean, a known name, or a word for a text option")
end

function parse_options(text)
    pairs = map(split(text, ","; keepempty = false)) do item
        m = match(r"^\s*([a-z_][a-z0-9_]*)\s*=\s*(\S+)\s*$", item)
        m === nothing && error("option $item is not name=value")
        name = Symbol(m[1])
        name in REFUSED_OPTIONS && error("option $name is set by the benchmark")
        name => option_value(name, m[2])
    end
    allunique(first.(pairs)) || error("an option is given twice in $text")
    return (; pairs...)
end

# Options on top of a configuration. Another linear solver drops the options of the configuration's
# own linear solver, such as those of MA57 in `default` on the host.
function custom_options(base, given)
    if haskey(given, :linear_solver)
        own = Set(fieldnames(MadNLP.MadNLPOptions))
        base = (; (k => v for (k, v) in pairs(base) if k in own)...)
    end
    return (; base..., given...)
end

# The same options in one order, which names a configuration: custom-<8 hex digits of its SHA-1>.
normalized_options(text) = join(sort!(map(strip, split(text, ","; keepempty = false))), ",")
custom_name(text) = "custom-" * bytes2hex(SHA.sha1(normalized_options(text)))[1:8]

function validate(configs)
    for (name, opts) in configs
        haskey(opts, :solver) && continue   # options of another solver
        known = Set(fieldnames(MadNLP.MadNLPOptions))
        haskey(opts, :linear_solver) && union!(known, fieldnames(typeof(MadNLP.default_options(opts.linear_solver))))
        unknown = setdiff(keys(opts), known)
        isempty(unknown) || error("configuration $name: unknown options $(join(unknown, ", "))")
    end
    return
end
