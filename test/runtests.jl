# libKriging ships its own Julia test-suite next to the binding; run it against
# the generated module (module name adapted on the fly).
using Test
using JLibKriging

include(joinpath(@__DIR__, "..", "deps", "deps.jl"))   # libkriging_source_dir
const TESTS = joinpath(libkriging_source_dir, "bindings", "Julia", "jlibkriging", "tests")

@testset "JLibKriging" begin
    @test isfile(libkriging_c_path)
    mktempdir() do tmp
        cd(tmp) do
            for f in sort(readdir(TESTS))
                (endswith(f, "_test.jl") && f != "jlibkriging_demo.jl") || continue
                code = replace(read(joinpath(TESTS, f), String), r"\bjlibkriging\b" => "JLibKriging")
                path = joinpath(tmp, f)
                write(path, code)
                println(stderr, "==> $f"); flush(stderr)   # locate a hang in the CI log
                @testset "$f" begin
                    include(path)
                end
            end
        end
    end
end
