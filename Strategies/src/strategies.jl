using Pkg: Pkg
using TimeTicks
using ExchangeTypes
using Collections: AssetCollection, Collections as coll
using Instances: AssetInstance
using OrderTypes: Order, OrderType, BuyOrder, SellOrder, Buy, Sell, OrderSide
using Data.DataFrames: nrow
using Instruments: AbstractAsset, Cash, cash!
using Misc

abstract type AbstractStrategy end

ExchangeAsset(E) = AssetInstance{T,E} where {T<:AbstractAsset}
ExchangeOrder(E) = Order{O,T,E} where {O<:OrderType,T<:AbstractAsset}
ExchangeBuyOrder(E) = BuyOrder{O,T,E} where {O<:OrderType,T<:AbstractAsset}
ExchangeSellOrder(E) = SellOrder{O,T,E} where {O<:OrderType,T<:AbstractAsset}
@doc """The strategy is the core type of the framework.

The strategy type is concrete according to:
- Name (Symbol)
- Exchange (ExchangeID), read from config
- Quote cash (Symbol), read from config
The exchange and the quote cash should be specified from the config, or the strategy module.

- `universe`: All the assets that the strategy knows about
- `holdings`: assets with non zero balance.
- `orders`: active orders
- `timeframe`: the smallest timeframe the strategy uses
- `cash`: the quote currency used for trades

Conventions for strategy defined attributes:
- `NAME`: the name of the strategy could be different from module name
- `S`: the strategy type.
- `TF`: the smallest `timeframe` that the strategy uses
"""
struct Strategy{M<:ExecMode,S,E<:ExchangeID} <: AbstractStrategy
    self::Module
    config::Config
    timeframe::TimeFrame
    cash::Cash{S1,Float64} where {S1}
    cash_committed::Cash{S2,Float64} where {S2}
    buyorders::Dict{ExchangeAsset(E),Set{ExchangeBuyOrder(E)}}
    sellorders::Dict{ExchangeAsset(E),Set{ExchangeSellOrder(E)}}
    holdings::Set{ExchangeAsset(E)}
    universe::AssetCollection
    function Strategy(
        self::Module,
        mode::Type{<:ExecMode},
        timeframe::TimeFrame,
        exc::Exchange,
        uni::AssetCollection;
        config::Config,
    )
        ca = Cash(config.qc, config.initial_cash)
        if !coll.iscashable(ca, uni)
            @warn "Assets within the strategy universe don't match the strategy cash! ($(nameof(ca)))"
        end
        ca_comm = Cash(config.qc, 0.0)
        eid = typeof(exc.id)
        holdings = Set{ExchangeAsset(eid)}()
        buyorders = Dict{ExchangeAsset(eid),Set{ExchangeBuyOrder(eid)}}()
        sellorders = Dict{ExchangeAsset(eid),Set{ExchangeSellOrder(eid)}}()
        name = nameof(self)
        new{mode,name,eid}(
            self, config, timeframe, ca, ca_comm, buyorders, sellorders, holdings, uni
        )
    end
end

include("methods.jl")
include("interface.jl")
include("load.jl")
include("utils.jl")
include("print.jl")

export Strategy, strategy, strategy!, reset!
export @interface, assets, exchange
export LoadStrategy, WarmupPeriod
