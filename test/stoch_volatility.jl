using ArgCheck
using Distributions
using Parameters
using DynamicHMC
using StatsBase
using StatPlots                 # for kernel density
import DynamicHMC: logdensity, loggradient, length
using Base.Test
using ForwardDiff
using ReverseDiff
using Plots
using ContinuousTransformations
using ProfileView

plotlyjs()                      # Tamas likes this, optional

"""
    simulate_stochastic(ρ, σ_v, ϵs, νs)

Take in the parameter values (ρ, σ) for the latent volatility process, the errors ϵs used for the measurement equation and the errors νs used for the transition equation.

The discrete-time version of the Ornstein-Ulenbeck Stochastic - volatility model:

    y_t = x_t + ϵ_t where ϵ_t ∼ χ^2(1)
    x_t = ρ * x_(t-1) + σ * ν_t  where ν_t ∼ N(0, 1)

"""
function simulate_stochastic(ρ, σ, ϵs, νs)
    N = length(ϵs)
    @argcheck N == length(νs)
    xs = Vector{Real}(N)
    for i in 1:N
        xs[i] = (i == 1) ? (νs[1]*σ*(1 - ρ^2)^(-0.5)) : (ρ*xs[i-1] + σ*νs[i])
    end
    xs + log.(ϵs) + 1.27
end

simulate_stochastic(ρ, σ, N) = simulate_stochastic(ρ, σ, rand(Chisq(1), N), randn(N))

struct Toy_Vol_Problem
    "observed data"
    ys
    "prior for ρ (persistence)"
    prior_ρ
    "prior for σ_v (volatility of volatility)"
    prior_σ
    "χ^2 draws for simulation"
    ϵ::Vector{Float64}
    "Normal(0,1) draws for simulation"
    ν::Vector{Float64}
end

"""
    Toy_Vol_Problem(ys, prior_ρ, prior_σ, M)

Convenience constructor for Toy_Vol_Problem.
Take in the observed data, the priors, and number of simulations (M).
"""
function Toy_Vol_Problem(ys, prior_ρ, prior_σ, M)
    Toy_Vol_Problem(ys, prior_ρ, prior_σ, rand(Chisq(1), M), randn(M))
end

"""
    simulate!(pp::Toy_Vol_Problem)

Updates the shocks of the model.
"""
function simulate!(pp::Toy_Vol_Problem)
    @unpack ϵ, ν = pp
    rand!(Chisq(1), ϵ)
    randn!(ν)
end

"""
    β, v = OLS(y, x)

Take in the dependant variable (y) and the regressor (x), give back the estimated coefficients (β) and the variance (v).
"""
function OLS(y, x)
    β = x \ y
    err = (y - x * β)
    v = mean(abs2, err)
    return β, v
end


## In this form, we use an AR(2) process of the first differences with an intercept as the auxiliary model.

"""
    lag(xs, n, K)

Lag-`n` operator on vector `xs` (maximum `K` lags).
"""
lag(xs, n, K) = xs[((K+1):end)-n]

lag_matrix(xs, ns, K = maximum(ns)) = hcat([lag(xs, n, K) for n in ns]...)

@test lag_matrix(1:5, 1:3) == [3 2 1; 4 3 2]

"first auxiliary regression y, X, meant to capture first differences"
function yX1(zs, K)
    Δs = diff(zs)
    lag(Δs, 0, K), hcat(lag_matrix(Δs, 1:K, K), ones(length(Δs)-K), lag(zs, 1, K+1))
end

"second auxiliary regression y, X, meant to capture levels"
function yX2(zs, K)
    lag(zs, 0, K), hcat(ones(length(zs)-K), lag_matrix(zs, 1:K, K))
end

function bridge_trans(dist::Distribution{Univariate,Continuous})
    supp = support(dist)
    bridge(ℝ, minimum(supp) .. maximum(supp))
end

parameter_transformations(pp::Toy_Vol_Problem) = bridge_trans.([pp.prior_ρ, pp.prior_σ])

function logdensity(pp::Toy_Vol_Problem, θ)
    @unpack ys, prior_ρ, prior_σ, ν, ϵ = pp
    trans = parameter_transformations(pp)

    value_and_logjac = [t(raw_θ, LOGJAC) for (t, raw_θ) in zip(trans, θ)]

    ρ, σ = first.(value_and_logjac)
    N = length(ϵ)
    logprior = logpdf(prior_ρ, ρ) + logpdf(prior_σ, σ) + sum(last, value_and_logjac)

    # Generating xs, which is the latent volatility process

    zs = simulate_stochastic(ρ, σ, ϵ, ν)
    β₁, v₁ = OLS(yX1(zs, 2)...)
    β₂, v₂ = OLS(yX2(zs, 2)...)

    # We work with first differences
    y₁, X₁ = yX1(ys, 2)
    log_likelihood1 = sum(logpdf.(Normal(0, √v₁), y₁ - X₁ * β₁))
    y₂, X₂ = yX2(ys, 2)
    log_likelihood2 = sum(logpdf.(Normal(0, √v₂), y₂ - X₂ * β₂))
    logprior + log_likelihood1 + log_likelihood2

end

# Trial
ρ = 0.8
σ = 0.6
y = simulate_stochastic(ρ, σ, 10000)
pp = Toy_Vol_Problem(y, Uniform(-1, 1), InverseGamma(1, 1), 10000)

θ₀ = [inv(t)(param) for (t,param) in zip(parameter_transformations(pp), [ρ, σ])]

## profiling
logdensity(pp, θ₀)
Profile.clear()
@profile logdensity(pp, θ₀)
ProfileView.view()







## with Forward mode AD
loggradient(pp::Toy_Vol_Problem, x) = ForwardDiff.gradient(y->logdensity(pp, y), x)
loggradient(pp, θ₀)
## with reverse mode AD
loggradient_rev(pp::Toy_Vol_Problem, x) = ReverseDiff.gradient(y->logdensity(pp, y), x)
loggradient_rev(pp, θ₀)
## seems like both work, but results are different

## length, pp does not have an element such that i could get hold of the length of the parameter vector
Base.length(::Toy_Vol_Problem) = 2.0
## defining RNG
const RNG = srand(UInt32[0x23ef614d, 0x8332e05c, 0x3c574111, 0x121aa2f4])
## problem with RNG, error message: no method matching randn(::MersenneTwister, ::Float64)
sample, tuned_sample = NUTS_tune_and_mcmc(RNG, pp, 1000; q = θ₀)