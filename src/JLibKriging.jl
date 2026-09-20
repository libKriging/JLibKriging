# The body of this module is generated at build time (Pkg.build, run
# automatically by Pkg.add) from libKriging's own Julia binding: see
# deps/build.jl.
module JLibKriging

const _generated = joinpath(@__DIR__, "..", "deps", "generated", "JLibKriging.jl")
isfile(_generated) || error(
    "JLibKriging has not been built yet. Run `import Pkg; Pkg.build(\"JLibKriging\")` " *
    "(requires a C++17 compiler and BLAS/LAPACK) and check its output.")
include(_generated)

end # module
