module StubStrategy

using ..Stubs.Misc
using ..Stubs.TimeTicks
using ..Data
using ..Data.DFUtils
using ..Data.DataFrames

using ..Strategies
using .Strategies.Instances.Instruments
using .Strategies: Strategies as st
using .Strategies.Exchanges.ExchangeTypes
using .Strategies: Instances as inst
using ..SimMode.Executors
using .Executors: Executors, Executors as ect
using .Strategies.OrderTypes
using .OrderTypes: BySide, ByPos

using ..Lang

const CACHE = Dict{Symbol,Any}()

# # NOTE: do not export anything
Strategies.@interface

const DESCRIPTION = "Strategy to generate stub data"
const EXC = :binance
const EXCID = ExchangeID(EXC)
const S{M} = Strategy{M,nameof(@__MODULE__),typeof(EXCID),NoMargin}
const SC{E,M,R} = Strategy{M,nameof(@__MODULE__()),E,R}
const TF = tf"1m"

# function __init__() end

function call!(::Type{<:S}, ::StrategyMarkets)
    ["ETH/USDT:USDT", "BTC/USDT:USDT", "SOL/USDT:USDT"]
end

function call!(t::Type{<:S}, config, ::LoadStrategy)
    syms = call!(S, StrategyMarkets())
    exc = st.Exchanges.getexchange!(config.exchange; sandbox=true)
    uni = st.AssetCollection(syms; load_data=false, timeframe=TF, exc, config.margin)
    s = Strategy(@__MODULE__, config.mode, config.margin, TF, exc, uni; config)
    s.attrs[:buydiff] = 1.01
    s.attrs[:selldiff] = 1.005
    s
end

call!(_::S, ::WarmupPeriod) = begin
    Day(1)
end

function call!(s::S, ts::DateTime, ctx)
    date = ts
    foreach(s.universe) do ai
        if isopen(ai)
            if rand(Bool)
                call!(s, ai, MarketOrder{Sell}; amount=cash(ai), date)
            end
        elseif cash(s) > ai.limits.cost.min && rand(Bool)
            call!(
                s,
                ai,
                MarketOrder{Buy};
                amount=max(ai.limits.amount.min, ai.limits.cost.min / closeat(ai, ts)),
                date,
            )
        end
    end
end

function buy!(s::S, ai, ats, ts)
    call!(s, ai, ect.CancelOrders(); t=Sell)
    @deassert ai.asset.qc == nameof(s.cash)
    price = closeat(ai.ohlcv, ats)
    amount = st.freecash(s) / 10.0 / price
    if amount > 0.0
        t = call!(s, ai, IOCOrder{Buy}; amount, date=ts)
    end
end

function sell!(s::S, ai, ats, ts)
    call!(s, ai, ect.CancelOrders(); t=Buy)
    amount = max(inv(closeat(ai, ats)), inst.freecash(ai))
    price = closeat(ai.ohlcv, ats)
    if amount > 0.0
        t = call!(s, ai, IOCOrder{Sell}; amount, date=ts)
    end
end

end
