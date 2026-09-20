# deps/build.jl -- run by `Pkg.build("JLibKriging")` (and automatically by
# `Pkg.add`).  Julia counterpart of rlibkriging's tools/setup.sh:
#
#   1. fetch the pinned libKriging sources (deps/sources.toml) -- a registered
#      package is a plain archive without git submodules, so everything is
#      downloaded as GitHub archives, no `git` needed;
#   2. patch the CMake files on the fly (regexps) so that only what the Julia
#      binding needs is configured;
#   3. compile `libkriging_c` (C API of libKriging) with cmake;
#   4. generate the `JLibKriging` module from libKriging's own Julia binding
#      (bindings/Julia/jlibkriging), renaming the module and pointing it at the
#      library we just built.
#
# Environment overrides (all optional):
#   LIBKRIGING_SRC_DIR      use this libKriging checkout (with its
#                           dependencies/ populated) instead of downloading
#   JLIBKRIGING_BUILD_JOBS  parallel build jobs (default: CPU threads)
#   JLIBKRIGING_CMAKE_ARGS  extra cmake configure arguments (space separated)
#   JLIBKRIGING_SYSTEM_BLAS set to 1 to link the system BLAS/LAPACK instead of
#                           OpenBLAS32_jll (the default on Linux and Windows;
#                           macOS always uses Accelerate)
#   CMAKE_GENERATOR         cmake generator (Windows default: "MinGW Makefiles")

using Downloads
using Libdl
using Pkg
using CMake_jll
using OpenBLAS32_jll
import Pkg.TOML

const DEPS = @__DIR__
const SRC = joinpath(DEPS, "src")
const BUILD = joinpath(DEPS, "build")
const USR = joinpath(DEPS, "usr")
const GENERATED = joinpath(DEPS, "generated")

log(msg) = println("[JLibKriging] ", msg)

# ---------------------------------------------------------------- 1. fetch --

function fetch_archive(repo::AbstractString, sha::AbstractString, dest::AbstractString)
    marker = joinpath(dest, ".jlibkriging-sha")
    if isfile(marker) && strip(read(marker, String)) == sha
        log("$repo@$(sha[1:8]) already present")
        return
    end
    rm(dest; recursive=true, force=true)
    mkpath(dirname(dest))
    url = "https://github.com/$repo/archive/$sha.tar.gz"
    log("downloading $url")
    tarball = Downloads.download(url, tempname() * ".tar.gz")
    tmp = mktempdir()
    try
        Pkg.PlatformEngines.unpack(tarball, tmp)
        # GitHub archives contain one top-level directory "<name>-<sha>"
        entries = readdir(tmp)
        length(entries) == 1 || error("unexpected archive layout for $repo: $entries")
        mv(joinpath(tmp, entries[1]), dest)
    finally
        rm(tarball; force=true)
        rm(tmp; recursive=true, force=true)
    end
    write(marker, sha)
end

function fetch_sources(sources)
    if !isempty(get(ENV, "LIBKRIGING_SRC_DIR", ""))
        dir = abspath(ENV["LIBKRIGING_SRC_DIR"])
        log("using LIBKRIGING_SRC_DIR=$dir")
        # patch a private copy: never modify the user's checkout
        work = joinpath(SRC, "libKriging")
        rm(work; recursive=true, force=true)
        mkpath(SRC)
        cp(dir, work; force=true)
        rm(joinpath(work, ".git"); recursive=true, force=true)
        rm(joinpath(work, "build"); recursive=true, force=true)
        slap = joinpath(SRC, "slapack")
        isdir(slap) || fetch_archive(sources["slapack"]["repo"], sources["slapack"]["sha"], slap)
        return work
    end
    lk = sources["libKriging"]
    work = joinpath(SRC, "libKriging")
    fetch_archive(lk["repo"], lk["sha"], work)
    for dep in sources["dependency"]
        fetch_archive(dep["repo"], dep["sha"], joinpath(work, dep["path"]))
    end
    fetch_archive(sources["slapack"]["repo"], sources["slapack"]["sha"], joinpath(SRC, "slapack"))
    return work
end

# ---------------------------------------------------------------- 2. patch --

function patch_file(path, subs::Pair...)
    isfile(path) || return
    s = read(path, String)
    for (pat, rep) in subs
        s = replace(s, pat => rep)
    end
    write(path, s)
end

"""
MinGW-w64 (GCC) rejects `dllimport` on a function that is *defined* inline, which
libKriging's headers do for a few members (`LIBKRIGING_EXPORT void f(..) { .. }`);
MSVC only warns. Inline code needs no export anyway: drop the macro from those
one-line definitions (declarations, ending with `;`, keep it).
"""
function patch_inline_exports(work)
    Sys.iswindows() || return
    pat = r"^([ \t]*)LIBKRIGING_EXPORT[ \t]+(?=[^\n]*\)[ \t]*(const[ \t]*)?(noexcept[ \t]*)?\{[^\n]*\}[ \t]*(//[^\n]*)?$)"m
    n = 0
    for (root, _, files) in walkdir(joinpath(work, "src", "lib", "include"))
        for f in files
            endswith(f, ".hpp") || continue
            path = joinpath(root, f)
            s = read(path, String)
            r = replace(s, pat => s"\1")
            if r != s
                n += length(collect(eachmatch(pat, s)))
                write(path, r)
            end
        end
    end
    log("removed LIBKRIGING_EXPORT from $n inline definition(s) (MinGW)")
end

function patch_cmake(work)
    top = joinpath(work, "CMakeLists.txt")
    # Only the C API library is needed: no unit tests, benchmarks, Catch2,
    # documentation nor unused bindings (same idea as rlibkriging's setup.sh).
    patch_file(top,
        r"^(\s*)(include\(CTest\))"m                        => s"\1##\2",
        r"^(\s*)(add_subdirectory\(tests\))"m               => s"\1##\2",
        r"^(\s*)(add_subdirectory\(bench\))"m               => s"\1##\2",
        r"^(\s*)(add_subdirectory\(\"\$\{CATCH_MODULE_PATH\}\"\))"m => s"\1##\2",
        r"^(\s*)(set\(CATCH_MODULE_PATH.*)$"m               => s"\1##\2",
        r"^(\s*)(configure_file\(\$\{DOXYGEN_IN\})"m        => s"\1##\2")
    # armadillo: use the local slapack sources instead of cloning them
    slap = replace(joinpath(SRC, "slapack"), "\\" => "/")
    patch_file(joinpath(work, "dependencies", "armadillo-code", "cmake_aux", "Modules", "ARMA_FindLAPACK.cmake"),
        "https://github.com/libKriging/slapack.git" => slap)
    patch_file(joinpath(work, "dependencies", "armadillo-code", "cmake_aux", "Tools", "build_external_project.cmake"),
        "GIT_REPOSITORY" => "SOURCE_DIR")
end

# ---------------------------------------------------------------- 3. build --

use_jll_blas() = !Sys.isapple() && get(ENV, "JLIBKRIGING_SYSTEM_BLAS", "") in ("", "0")

function libname()
    Sys.iswindows() ? "libkriging_c.dll" : Sys.isapple() ? "libkriging_c.dylib" : "libkriging_c.so"
end

function build_library(work)
    rm(BUILD; recursive=true, force=true)
    mkpath(BUILD)
    jobs = get(ENV, "JLIBKRIGING_BUILD_JOBS", string(max(1, Sys.CPU_THREADS)))
    args = String[
        "-S", work, "-B", BUILD,
        "-DCMAKE_BUILD_TYPE=Release",
        "-DENABLE_JULIA_BINDING=ON",
        "-DENABLE_PYTHON_BINDING=OFF",
        "-DENABLE_OCTAVE_BINDING=OFF",
        "-DENABLE_MATLAB_BINDING=OFF",
        "-DENABLE_R_BINDING=OFF",
        # the libraries are copied side by side into deps/usr/lib and the build
        # tree is removed: make them find each other there
        "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON",
        "-DCMAKE_INSTALL_RPATH=" * (Sys.isapple() ? "@loader_path" : "\$ORIGIN"),
    ]
    if use_jll_blas()
        # libKriging needs BLAS + LAPACK with 32-bit integers and standard
        # symbol names: OpenBLAS32_jll provides both, so no system library nor
        # compiler-specific setup is required (a runner without liblapack-dev
        # would otherwise yield an armadillo built WITHOUT LAPACK).
        push!(args, "-DOPENBLAS_PROVIDES_LAPACK=ON",
                    "-Dopenblas_LIBRARY=" * replace(OpenBLAS32_jll.libopenblas_path, "\\" => "/"))
    end
    if Sys.iswindows()
        # CMake_jll's cmake defaults to NMake; the OpenBLAS32_jll DLL is built
        # with MinGW-w64, like Julia itself and like rlibkriging on Windows.
        if isempty(get(ENV, "CMAKE_GENERATOR", ""))
            push!(args, "-G", "MinGW Makefiles")
        end
        push!(args, "-DCMAKE_SHARED_LINKER_FLAGS=-static-libgcc -static-libstdc++",
                    "-DCMAKE_EXE_LINKER_FLAGS=-static-libgcc -static-libstdc++")
        # Julia's process already holds its own MinGW runtime (libwinpthread,
        # libgcc_s, ...): a libgomp from a newer compiler cannot bind to those
        # ("The specified procedure could not be found"). Use OpenMP only if
        # Julia ships libgomp itself, i.e. a consistent runtime; else run
        # libKriging's multistart optimisation sequentially.
        if !isfile(joinpath(Sys.BINDIR, "libgomp-1.dll"))
            log("no libgomp-1.dll in Julia's bin directory: building without OpenMP")
            push!(args, "-DCMAKE_DISABLE_FIND_PACKAGE_OpenMP=ON")
        end
    end
    extra = split(get(ENV, "JLIBKRIGING_CMAKE_ARGS", ""))
    append!(args, extra)
    cmake = CMake_jll.cmake()
    log("configuring libKriging (cmake)")
    run(`$cmake $args`)
    log("building libkriging_c with $jobs jobs (this can take several minutes)")
    run(`$cmake --build $BUILD --config Release --target libkriging_c --parallel $jobs`)
    # locate the library in the build tree (single- or multi-config generators)
    found = String[]
    for (root, _, files) in walkdir(BUILD)
        libname() in files && push!(found, joinpath(root, libname()))
    end
    isempty(found) && error("$(libname()) not found in $BUILD after the build")
    mkpath(joinpath(USR, "lib"))
    lib = joinpath(USR, "lib", libname())
    cp(first(sort(found; by=length)), lib; force=true)
    # shared libraries the C API depends on (e.g. libKriging, armadillo) sit
    # next to it in the build tree: ship all of them beside libkriging_c
    ext = Sys.iswindows() ? ".dll" : Sys.isapple() ? ".dylib" : ".so"
    for (root, _, files) in walkdir(BUILD)
        for f in files
            if occursin(ext, f) && f != libname() && !occursin("CMakeFiles", root)
                cp(joinpath(root, f), joinpath(USR, "lib", f); force=true, follow_symlinks=false)
            end
        end
    end
    Sys.iswindows() && bundle_mingw_runtime(joinpath(USR, "lib"))
    rm(BUILD; recursive=true, force=true)
    return lib
end

"""
Windows/MinGW: the libraries import DLLs that are not on Julia's search path
(the compiler's runtime -- libgomp, libwinpthread, ... -- and OpenBLAS32_jll's
libopenblas). Read the imports with objdump and copy the ones found in the
compiler's bin directory or in OpenBLAS32_jll's, next to libkriging_c.dll (the
directory of a DLL is searched first when it is loaded). Whatever remains
unresolved (neither bundled, nor in Julia's bin directory, nor a Windows
system DLL) is reported, to make a failure to load diagnosable.
"""
function bundle_mingw_runtime(libdir)
    cache = read(joinpath(BUILD, "CMakeCache.txt"), String)
    m = match(r"^CMAKE_CXX_COMPILER:[A-Z]+=(.+)$"m, cache)
    m === nothing && (log("compiler not found in CMakeCache: runtime DLLs not bundled"); return)
    gccbin = dirname(strip(m.captures[1]))
    objdump = joinpath(gccbin, "objdump.exe")
    isfile(objdump) || (log("objdump not found next to the compiler ($gccbin): runtime DLLs not bundled"); return)
    sources = [gccbin, dirname(OpenBLAS32_jll.libopenblas_path)]
    sysdirs = [Sys.BINDIR, joinpath(get(ENV, "SystemRoot", "C:\\Windows"), "System32")]
    done = Set{String}()
    queue = filter(f -> endswith(lowercase(f), ".dll"), readdir(libdir))
    while !isempty(queue)
        dll = popfirst!(queue)
        lowercase(dll) in done && continue
        push!(done, lowercase(dll))
        out = read(`$objdump -p $(joinpath(libdir, dll))`, String)
        for mm in eachmatch(r"DLL Name:\s*(\S+)"i, out)
            dep = mm.captures[1]
            isfile(joinpath(libdir, dep)) && continue
            # already provided by Julia itself (its MinGW runtime): a same-named DLL
            # is resolved to the one loaded in the process anyway, and mixing
            # versions is what breaks the load -- use Julia's
            if isfile(joinpath(Sys.BINDIR, dep))
                log("$dep (needed by $dll) is provided by Julia")
                continue
            end
            idx = findfirst(d -> isfile(joinpath(d, dep)), sources)
            if idx !== nothing
                log("bundling $dep (needed by $dll) from $(sources[idx])")
                cp(joinpath(sources[idx], dep), joinpath(libdir, dep))
                push!(queue, dep)
            elseif !any(d -> isfile(joinpath(d, dep)), sysdirs) && !startswith(lowercase(dep), "api-ms-win-")
                log("WARNING: $dep (needed by $dll) was not found anywhere")
            end
        end
    end
end

# -------------------------------------------------------------- 4. wrapper --

"""
Turn libKriging's `bindings/Julia/jlibkriging/src/jlibkriging.jl` into the
`JLibKriging` module: rename it and default the library path to the one built
by this script (`JLIBKRIGING_LIB_PATH` still takes precedence).
"""
_sub(s, p::Pair) = (r = replace(s, p); (r, r == s ? 0 : 1))

function generate_module(work, lib)
    src = joinpath(work, "bindings", "Julia", "jlibkriging", "src", "jlibkriging.jl")
    isfile(src) || error("libKriging's Julia binding not found: $src")
    s = read(src, String)
    # the body only: src/JLibKriging.jl defines `module JLibKriging` and includes it
    s, n1 = _sub(s, r"^module jlibkriging[^\n]*\n"m => "")
    s, n2 = _sub(s, r"\nend[ \t]*(#[^\n]*)?\s*$" => "\n")
    (n1 == 1 && n2 == 1) || error("unexpected module layout in jlibkriging.jl (module line: $n1, final end: $n2): " *
                                  "libKriging's binding changed, update deps/build.jl")
    # documentation / error messages mention the old name (renamed BEFORE the
    # library path is inserted, so that path is never touched)
    s = replace(s, r"\bjlibkriging\b" => "JLibKriging")
    # libKriging <= 1.2.1: the deprecated `get_*` aliases pass the *function* to
    # `Base.depwarn`, which expects a Symbol (MethodError on recent Julia).
    # Tolerant patch: a no-op once libKriging fixes it upstream.
    s = replace(s, r"(Base\.depwarn\([^\n]*?),\s*\$\(_old\)\)" => s"\1, $(QuoteNode(_old)))")
    pat = r"get\(ENV,\s*\"JLIBKRIGING_LIB_PATH\",\s*\"\"\)"
    n = length(collect(eachmatch(pat, s)))
    n == 1 || error("could not point the wrapper at the built library (expected 1 match, got $n): " *
                    "libKriging's jlibkriging.jl changed, update deps/build.jl")
    if use_jll_blas()
        # libkriging_c is linked against OpenBLAS32_jll's library: loading the JLL
        # first makes the dynamic loader resolve that dependency by name.
        s, nj = _sub(s, r"^using Libdl[^\n]*\n"m => "using Libdl\nusing OpenBLAS32_jll  # provides BLAS/LAPACK to libkriging_c\n")
        nj == 1 || error("no `using Libdl` line in jlibkriging.jl: update deps/build.jl")
    end
    # Windows only applies the "altered search path" (the DLL's own directory
    # is searched first for its dependencies) to a path written with
    # backslashes: with forward slashes libkriging_c.dll cannot find the DLLs
    # bundled next to it ("The specified module could not be found").
    libpath = Sys.iswindows() ? replace(lib, "/" => "\\") : lib
    s = replace(s, pat => "get(ENV, \"JLIBKRIGING_LIB_PATH\", raw\"$libpath\")")
    mkpath(GENERATED)
    out = joinpath(GENERATED, "JLibKriging.jl")
    write(out, "# GENERATED by deps/build.jl from libKriging's jlibkriging.jl -- do not edit.\n" * s)
    return out
end

function main()
    sources = TOML.parsefile(joinpath(DEPS, "sources.toml"))
    work = fetch_sources(sources)
    patch_cmake(work)
    patch_inline_exports(work)
    lib = build_library(work)
    generate_module(work, lib)
    write(joinpath(DEPS, "deps.jl"),
          "const libkriging_c_path = raw\"$(replace(lib, "\\" => "/"))\"\n" *
          "const libkriging_source_dir = raw\"$(replace(work, "\\" => "/"))\"\n")
    log("done: $lib")
end

main()
