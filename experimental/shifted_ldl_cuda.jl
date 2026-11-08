# The CUDA methods of the shifted LDL experiment, included into its module when cuMadNLP is loaded.
using CUDA, CUDA.CUSPARSE
const cuMadNLP = Main.cuMadNLP
_nz(A::CuSparseMatrixCSC) = A.nzVal
_rows(A::CuSparseMatrixCSC) = Array(A.rowVal)
_colptr(A::CuSparseMatrixCSC) = Array(A.colPtr)
_nz(A::CuSparseMatrixCSR) = A.nzVal
# symmetric, so its rows are the columns of the full CSC pattern
_full(A::CuSparseMatrixCSC, colptr, rowval, nz) = CuSparseMatrixCSR(colptr, rowval, nz, size(A))
_device(::CuSparseMatrixCSC, v::Vector) = CuArray(v)
function _inner(A::CuSparseMatrixCSC, eps, logger)
    opt = MC.default_options(cuMadNLP.CUDSSSolver)
    opt.cudss_algorithm = MC.LDL
    opt.cudss_pivot_epsilon = eps
    return MC.create_linear_solver(cuMadNLP.CUDSSSolver, A; opt, logger)
end
function _ruiz_kernel!(dnew, d, colptr, rowval, absnz)
    j = (blockIdx().x - 1) * blockDim().x + threadIdx().x
    if j <= length(dnew)
        r = zero(eltype(d))
        for k in colptr[j]:(colptr[j + 1] - 1)
            r = max(r, absnz[k] * d[rowval[k]])
        end
        r *= d[j]
        dnew[j] = r > 0 ? d[j] / sqrt(r) : d[j]
    end
    return
end
function _ruiz_sweep!(dnew::CuVector, d, colptr, rowval, absnz)
    n = length(dnew)
    @cuda threads = 256 blocks = cld(n, 256) _ruiz_kernel!(dnew, d, colptr, rowval, absnz)
    return dnew
end
