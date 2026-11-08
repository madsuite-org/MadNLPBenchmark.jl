# An experimental linear solver after ShiftedKKT: Ruiz equilibration of the KKT matrix, a -delta
# shift on its constraint block, a static LDL' factorization with a pivot bound (CHOLMOD on the
# host, cuDSS on a CUDA device) used as a preconditioner, inertia from that factorization, and
# GMRES on the unshifted matrix, accepted on the componentwise backward error.
module ShiftedLDLExperiment

using LinearAlgebra, SparseArrays, MadNLP
const MC = MadNLP.MadCore

export ShiftedLDL

struct ShiftedLDL end

Base.@kwdef mutable struct ShiftedLDLOptions <: MC.AbstractOptions
    shiftedkkt_delta::Float64 = 1.0e-10
    shiftedkkt_eps::Float64 = 1.0e-10
    shiftedkkt_ruiz_sweeps::Int = 4
    shiftedkkt_gmres_restart::Int = 50
    shiftedkkt_gmres_cycles::Int = 2
    shiftedkkt_omega_tol::Float64 = 1.0e-6
    shiftedkkt_rtol::Float64 = 1.0e-14
    n_primal::Int = 0
    n_dual::Int = 0
end

_nz(A::SparseMatrixCSC) = A.nzval
_rows(A::SparseMatrixCSC) = A.rowval
_colptr(A::SparseMatrixCSC) = A.colptr
_full(A::SparseMatrixCSC, colptr, rowval, nz) = SparseMatrixCSC(size(A)..., colptr, rowval, nz)
_device(::SparseMatrixCSC, v::Vector) = v

function _inner(A::SparseMatrixCSC, eps, logger)
    opt = MC.default_options(MC.CHOLMODSolver)
    opt.cholmod_algorithm = MC.LDL
    opt.cholmod_dbound = eps
    return MC.create_linear_solver(MC.CHOLMODSolver, A; opt, logger)
end

# one Ruiz sweep on the full symmetric matrix, stored by columns: dnew = d / sqrt(max_i |K_ij| d_i d_j)
function _ruiz_sweep!(dnew::Vector, d, colptr, rowval, absnz)
    @inbounds for j in eachindex(dnew)
        r = zero(eltype(d))
        for k in colptr[j]:(colptr[j + 1] - 1)
            r = max(r, absnz[k] * d[rowval[k]])
        end
        r *= d[j]
        dnew[j] = r > 0 ? d[j] / sqrt(r) : d[j]
    end
    return dnew
end

mutable struct ShiftedLDLState{T, MT, FT, VT, VI, MM} <: MC.AbstractLinearSolver{T}
    tril::MT                 # the KKT matrix handed over by MadNLP (lower triangle)
    fac::MT                  # its scaled and shifted copy, factorized by `inner`
    full::FT                 # the full symmetric matrix, for products with K
    fullabs::FT              # the same with |K_ij|
    fmap::VI                 # full nonzero -> tril nonzero
    frow::VI; fcolptr::VI    # pattern of `full`
    trow::VI; tcol::VI       # row and column of every tril nonzero
    tdiag::Vector{Int}       # tril nonzero of every diagonal entry (host)
    shift_idx::VI            # tril nonzeros of the diagonal of the constraint block
    inner::Any
    d::VT; dnew::VT
    x::VT; r::VT; z::VT; tmp::VT; ob::VT; w1::VT; w2::VT; onesv::VT
    Vm::MM
    opt::ShiftedLDLOptions
    logger::Any
end

function ShiftedLDLState(A; opt = ShiftedLDLOptions(), logger = MC.MadNLPLogger())
    T = eltype(_nz(A))
    n = size(A, 1)
    colptr = Vector{Int}(_colptr(A)); rows = Vector{Int}(_rows(A))
    cols = similar(rows); tdiag = zeros(Int, n)
    for j in 1:n, k in colptr[j]:(colptr[j + 1] - 1)
        cols[k] = j
        rows[k] == j && (tdiag[j] = k)
    end
    any(iszero, tdiag) && error("ShiftedLDL needs every diagonal entry in the pattern")
    off = rows .!= cols
    S = sparse(vcat(rows, cols[off]), vcat(cols, rows[off]), vcat(1:length(rows), findall(off)), n, n)
    Ti = eltype(_rows(A))
    dv(v) = _device(A, v)
    fcolptr = dv(Ti.(S.colptr)); frow = dv(Ti.(S.rowval))
    full = _full(A, fcolptr, frow, dv(zeros(T, nnz(S))))
    fullabs = _full(A, fcolptr, frow, dv(zeros(T, nnz(S))))
    fac = copy(A)
    inner = _inner(fac, opt.shiftedkkt_eps, logger)
    z() = dv(zeros(T, n))
    Vm = similar(z(), n, opt.shiftedkkt_gmres_restart + 1)
    fmap = dv(Ti.(S.nzval))
    return ShiftedLDLState{T, typeof(A), typeof(full), typeof(Vm[:, 1]), typeof(fmap), typeof(Vm)}(A, fac, full, fullabs, fmap, frow, fcolptr, dv(Ti.(rows)), dv(Ti.(cols)),
        tdiag, dv(Ti[]), inner, z(), z(), z(), z(), z(), z(), z(), z(), z(), dv(ones(T, n)), Vm, opt, logger)
end

function MC.factorize!(M::ShiftedLDLState{T}) where {T}
    np = M.opt.n_primal
    np > 0 || error("ShiftedLDL: the primal block size is not set")
    if length(M.shift_idx) != size(M.tril, 1) - np
        M.shift_idx = _device(M.tril, eltype(M.trow).(M.tdiag[(np + 1):end]))
    end
    tnz = _nz(M.tril)
    _nz(M.full) .= @view tnz[M.fmap]
    _nz(M.fullabs) .= abs.(_nz(M.full))
    fill!(M.d, one(T))
    for _ in 1:M.opt.shiftedkkt_ruiz_sweeps
        _ruiz_sweep!(M.dnew, M.d, M.fcolptr, M.frow, _nz(M.fullabs))
        M.d, M.dnew = M.dnew, M.d
    end
    _nz(M.fac) .= tnz .* view(M.d, M.trow) .* view(M.d, M.tcol)
    view(_nz(M.fac), M.shift_idx) .-= T(M.opt.shiftedkkt_delta)
    MC.factorize!(M.inner)
    return M
end

MC.is_inertia(::ShiftedLDLState) = true
MC.inertia(M::ShiftedLDLState) = MC.inertia(M.inner)
MC.improve!(::ShiftedLDLState) = false
MC.introduce(::ShiftedLDLState) = "shifted LDL (Ruiz scaling, -delta shift, static LDL', GMRES)"
for S in (ShiftedLDL, ShiftedLDLState)
    @eval MC.input_type(::Type{$S}) = :csc
    @eval MC.default_options(::Type{$S}) = ShiftedLDLOptions()
    @eval MC.is_supported(::Type{$S}, ::Type{Float64}) = true
end
MC.create_linear_solver(::Type{ShiftedLDL}, A; opt = ShiftedLDLOptions(), logger = MC.MadNLPLogger(), kwargs...) =
    ShiftedLDLState(A; opt, logger)

function apply!(M::ShiftedLDLState, out, rhs)
    M.ob .= M.d .* rhs
    MC.solve_linear_system!(M.inner, M.ob)
    out .= M.d .* M.ob
    return out
end

function givens!(H, cs, sn, g, j)
    for i in 1:(j - 1)
        t = cs[i] * H[i, j] + sn[i] * H[i + 1, j]
        H[i + 1, j] = -sn[i] * H[i, j] + cs[i] * H[i + 1, j]
        H[i, j] = t
    end
    d = hypot(H[j, j], H[j + 1, j])
    d > 0 ? (cs[j] = H[j, j] / d; sn[j] = H[j + 1, j] / d) : (cs[j] = one(d); sn[j] = zero(d))
    H[j, j] = d; H[j + 1, j] = zero(d)
    g[j + 1] = -sn[j] * g[j]; g[j] = cs[j] * g[j]
    return
end

# one restarted GMRES cycle on K, preconditioned by the factorization, added to x
function gmres_cycle!(M::ShiftedLDLState{T}, x, r) where {T}
    mres = M.opt.shiftedkkt_gmres_restart
    Vm, z = M.Vm, M.z
    apply!(M, z, r)
    beta = norm(z)
    (isfinite(beta) && beta > 0) || return 0
    view(Vm, :, 1) .= z ./ beta
    H = zeros(T, mres + 1, mres); g = zeros(T, mres + 1); g[1] = beta
    cs = zeros(T, mres); sn = zeros(T, mres)
    jused = 0
    for j in 1:mres
        mul!(M.tmp, M.full, view(Vm, :, j))
        apply!(M, z, M.tmp)
        nz0 = norm(z)
        Vj = view(Vm, :, 1:j)
        h = zeros(T, j)
        for _ in 1:2   # classical Gram-Schmidt, twice
            hd = Vj' * z
            mul!(z, Vj, hd, -one(T), one(T))
            h .+= Array(hd)
        end
        nrm = norm(z)
        H[1:j, j] .= h
        H[j + 1, j] = isfinite(nrm) ? nrm : zero(T)
        brk = !isfinite(nrm) || nrm <= sqrt(eps(T)) * nz0
        brk || (view(Vm, :, j + 1) .= z ./ nrm)
        givens!(H, cs, sn, g, j)
        jused = j
        (brk || abs(g[j + 1]) <= T(1.0e-4) * beta) && break
    end
    jused == 0 && return 0
    y = UpperTriangular(H[1:jused, 1:jused]) \ g[1:jused]
    mul!(x, view(Vm, :, 1:jused), copyto!(similar(x, jused), y), one(T), one(T))
    return jused
end

# componentwise backward error max_i |r_i| / (|K| |x| + |b|)_i
function omega(M::ShiftedLDLState{T}, x, r, b) where {T}
    den, rs = M.w1, M.w2
    M.tmp .= abs.(x)
    mul!(den, M.fullabs, M.tmp)
    den .+= abs.(b)
    thr = length(den) * eps(T) * maximum(den)
    mul!(rs, M.fullabs, M.onesv)
    xmax = maximum(M.tmp)
    den .= ifelse.(den .> thr, den, den .+ rs .* xmax)
    return maximum(abs.(r) ./ (den .+ floatmin(T)))
end

function MC.solve_linear_system!(M::ShiftedLDLState{T}, b::AbstractVector{T}) where {T}
    nb = norm(b)
    (isfinite(nb) && nb != 0) || return b
    x, r = M.x, M.r
    apply!(M, x, b)
    for _ in 1:M.opt.shiftedkkt_gmres_cycles
        r .= b
        mul!(r, M.full, x, -one(T), one(T))
        w = omega(M, x, r, b)
        ((isfinite(w) && w <= M.opt.shiftedkkt_omega_tol) || norm(r) / nb <= M.opt.shiftedkkt_rtol) && break
        gmres_cycle!(M, x, r)
    end
    copyto!(b, x)
    return b
end

isdefined(Main, :cuMadNLP) && include(joinpath(@__DIR__, "shifted_ldl_cuda.jl"))

end
