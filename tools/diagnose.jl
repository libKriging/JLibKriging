# Step-by-step smoke test with flushed output, to locate a hang/crash in CI
# (run with a step timeout): julia --project=. tools/diagnose.jl
step(msg) = (println("[diagnose] ", msg); flush(stdout))
step("julia $(VERSION), threads=$(Threads.nthreads()), OMP_NUM_THREADS=$(get(ENV, "OMP_NUM_THREADS", "<unset>"))")
step("1/6 using JLibKriging")
using JLibKriging
step("2/6 dlopen libkriging_c")
JLibKriging._lk()
step("3/6 Kriging(\"gauss\") (no data)")
k0 = Kriging("gauss")
X = reshape(collect(range(0.0, 1.0; length=8)), :, 1)
y = sin.(6 .* X[:, 1])
step("4/6 fit with optim=none and fixed parameters (no optimizer, one factorisation)")
k1 = Kriging(y, X, "gauss"; optim="none",
             parameters=Dict("theta" => [0.3], "sigma2" => 1.0, "is_sigma2_estim" => false, "is_theta_estim" => false))
step("5/6 predict")
m, s = predict(k1, reshape([0.25, 0.75], :, 1))
step("   -> mean = $m")
step("6/6 fit with the BFGS optimizer")
k2 = Kriging(y, X, "gauss")
step("done: theta = $(theta(k2))")
