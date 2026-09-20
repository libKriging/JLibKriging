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

using Downloads
using Libdl
using Pkg
using CMake_jll
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
    rm(BUILD; recursive=true, force=true)
    return lib
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
    libpath = replace(lib, "\\" => "/")
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
    lib = build_library(work)
    generate_module(work, lib)
    write(joinpath(DEPS, "deps.jl"),
          "const libkriging_c_path = raw\"$(replace(lib, "\\" => "/"))\"\n" *
          "const libkriging_source_dir = raw\"$(replace(work, "\\" => "/"))\"\n")
    log("done: $lib")
end

main()
