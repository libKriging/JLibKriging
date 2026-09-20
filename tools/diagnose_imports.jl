# Windows diagnostic: for every DLL in deps/usr/lib, list the imported symbols
# that the providing DLL does not export -- the cause of "The specified
# procedure could not be found" (Windows binds all imports at load time).
#   julia --project=. tools/diagnose_imports.jl
using OpenBLAS32_jll

objdump = something(Sys.which("objdump"), "C:/mingw64/bin/objdump.exe")
libdir = normpath(joinpath(@__DIR__, "..", "deps", "usr", "lib"))
dirs = [libdir, dirname(OpenBLAS32_jll.libopenblas_path), Sys.BINDIR,
        joinpath(get(ENV, "SystemRoot", "C:\\Windows"), "System32"), dirname(objdump)]
println("objdump = $objdump\nlibdir  = $libdir\nlibopenblas = $(OpenBLAS32_jll.libopenblas_path)")
# raw excerpt of libkriging_c.dll's import table, to validate the parsing below
let raw = readlines(`$objdump -p $(joinpath(libdir, "libkriging_c.dll"))`)
    i = findfirst(l -> occursin("DLL Name:", l), raw)
    println("--- raw objdump excerpt (libkriging_c.dll)")
    i === nothing || foreach(l -> println("    ", l), raw[max(1, i - 3):min(end, i + 8)])
    println("---")
end

function imports(dll)
    out = Dict{String,Vector{String}}()
    cur = nothing
    for line in eachline(`$objdump -p $dll`)
        m = match(r"DLL Name:\s*(\S+)"i, line)
        if m !== nothing
            cur = m.captures[1]; out[cur] = String[]; continue
        end
        if cur !== nothing
            # member lines: "<vma>  <ordinal|<none>>  <hint>  <name>  [bound-to]"
            mm = match(r"^\s+[0-9a-f]+\s+(?:<none>|\d+)\s+[0-9a-f]+\s+([A-Za-z_@?\$][^\s]*)"i, line)
            mm !== nothing && push!(out[cur], mm.captures[1])
        end
    end
    return out
end

# every whitespace-separated token of `objdump -p`: an exported name is one of them
# (robust against the exact layout of the export table)
exports(dll) = Set{String}(split(read(`$objdump -p $dll`, String)))

findprovider(name) = (i = findfirst(d -> isfile(joinpath(d, name)), dirs); i === nothing ? nothing : joinpath(dirs[i], name))

let wp = joinpath(Sys.BINDIR, "libwinpthread-1.dll")
    if isfile(wp)
        ex = exports(wp)
        println("Julia's libwinpthread-1.dll: clock_gettime64=$(("clock_gettime64" in ex)) ",
                "nanosleep64=$(("nanosleep64" in ex)) pthread_create=$(("pthread_create" in ex))")
    end
end

cache = Dict{String,Set{String}}()
nbad = 0
for dll in filter(f -> endswith(lowercase(f), ".dll"), readdir(libdir))
    println("== $dll")
    for (dep, syms) in imports(joinpath(libdir, dll))
        startswith(lowercase(dep), "api-ms-win-") && continue   # virtual API sets
        p = findprovider(dep)
        if p === nothing
            println("   $dep: PROVIDER NOT FOUND ($(length(syms)) symbols)"); global nbad += 1; continue
        end
        ex = get!(() -> exports(p), cache, p)
        missing_syms = filter(!in(ex), syms)
        status = isempty(missing_syms) ? "ok" : "MISSING $(length(missing_syms)) of $(length(syms)): " * join(first(missing_syms, 12), " ")
        println("   $dep ($(dirname(p))): $status")
        isempty(missing_syms) || (global nbad += 1)
    end
end
println(nbad == 0 ? "no unresolved import found" : "$nbad import problem(s)")
