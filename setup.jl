# Point the environment at a MadNLP checkout and install it.
#
#     julia setup.jl MADNLP [--hsl=PATH]
#
# MADNLP is a checkout of MadNLP.jl at the commit to benchmark. It is linked as madnlp/, from
# which the environment takes MadNLP and its packages and whose commit the results record.
# --hsl develops a licensed HSL_jll, for MA57 on the host. A dependency that MadNLP's packages take
# from a repository rather than the registry (`[sources]`, `Krylov = {url = ..., rev = ...}`) is
# taken from there here too: Pkg reads `[sources]` of the active project only, not of its packages.

using Pkg, TOML

function main(args)
    pos = filter(!startswith("--"), args)
    length(pos) == 1 || error("usage: julia setup.jl MADNLP [--hsl=PATH]")
    madnlp = abspath(only(pos))
    isdir(joinpath(madnlp, "MadNLPCore")) || error("$madnlp is not a checkout of MadNLP.jl")
    # Pkg does not hold a package taken from a path to [compat], so the bounds are checked here
    compat = TOML.parsefile(joinpath(@__DIR__, "Project.toml"))["compat"]
    for pkg in ("MadCore", "MadCoreGPU", "MadNLP", "MadNLPCore", "cuMadNLP")
        version = VersionNumber(TOML.parsefile(joinpath(madnlp, pkg, "Project.toml"))["version"])
        version in Pkg.Versions.semver_spec(compat[pkg]) ||
            error("$pkg $version in $madnlp is outside the [compat] bound $(compat[pkg]) of this benchmark")
    end
    link = joinpath(@__DIR__, "madnlp")
    islink(link) && rm(link)
    ispath(link) && error("$link exists and is not a link")
    symlink(madnlp, link)
    Pkg.activate(@__DIR__)
    for a in args
        m = match(r"^--hsl=(.*)$", a)
        m === nothing || Pkg.develop(path = abspath(m[1]))
    end
    # a fresh depot has no registry, and resolving needs one
    isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add("General")
    for (name, spec) in repository_sources(madnlp)
        println("taking $name from $(spec["url"])", haskey(spec, "rev") ? " at $(spec["rev"])" : "")
        Pkg.add(PackageSpec(; name, url = spec["url"], rev = get(spec, "rev", nothing), subdir = get(spec, "subdir", nothing)))
    end
    Pkg.resolve()
    Pkg.instantiate()
    Pkg.activate(joinpath(@__DIR__, "format"))
    Pkg.instantiate()
    println("benchmarking ", readchomp(`git -C $link rev-parse HEAD`), " from ", madnlp)
    return
end

# The dependencies MadNLP's packages here take from a repository, `name => {"url", "rev"}`; they
# must agree with each other.
function repository_sources(madnlp)
    ours = ("MadCore", "MadCoreGPU", "MadNLP", "MadNLPCore", "cuMadNLP")
    found = Dict{String, Dict{String, Any}}()
    pinned = get(TOML.parsefile(joinpath(@__DIR__, "Project.toml")), "sources", Dict())
    for pkg in ours
        for (name, spec) in get(TOML.parsefile(joinpath(madnlp, pkg, "Project.toml")), "sources", Dict())
            (name in ours || !(spec isa Dict) || !haskey(spec, "url")) && continue
            # the benchmark's own pins (the models, their packages) stay as they are
            haskey(pinned, name) && (println("$name: $pkg takes it from $(spec["url"]); the benchmark keeps its own"); continue)
            spec = Dict{String, Any}(k => spec[k] for k in ("url", "rev", "subdir") if haskey(spec, k))
            get(found, name, spec) == spec || error("$pkg takes $name from $spec, another package of $madnlp from $(found[name])")
            found[name] = spec
        end
    end
    return sort!(collect(found); by = first)
end

main(ARGS)
