module Strategies
using Pkg: Pkg
using Dates: DateTime
using ExchangeTypes
using Exchanges: getexchange!
using Misc: Config, config, Iterable, Candle
using Instruments: Asset, Cash
using ..Collections
using ..Instances
using ..Orders
using ..LiveOrders
using Instruments
using TimeTicks

struct Strategy42{M,E,C}
    universe::AssetCollection
    balances::Dict{Asset,Ref{AssetInstance{Asset,ExchangeID{E}}}}
    orders::Dict{Asset,Ref{AssetInstance{Asset,ExchangeID{E}}}}
    cash::Cash{C}
    config::Config
    Strategy42(src::Symbol, assets::Union{Dict,Iterable{String}}, config::Config) = begin
        exc = getexchange!(config.exchange)
        uni = AssetCollection(assets; exc)
        ca = Cash(config.qc, config.initial_cash)
        eid = typeof(exc.id)
        pf = Dict{Asset,Ref{AssetInstance{Asset,eid}}}()
        orders = Dict{Asset,Ref{AssetInstance{Asset,eid}}}()
        new{src,exc.id, config.qc}(uni, pf, orders, ca, config,)
    end
end
@doc """The strategy is the core type of the framework.

The strategy type is concrete according to:
- Name (Symbol)
- Exchange (ExchangeID), read from config
- Quote cash (Symbol), read from config
The exchange and the quote cash should be specified from the config, or the strategy module.

- `universe`: All the assets that the strategy knows about
- `balances`: assets with open orders or non zero balance.
- `orders`: all active orders
- `cash`: the quote currency used for trades
"""
Strategy = Strategy42

@doc "Clears all orders history from strategy."
clearorders!(strat::Strategy) = begin
    empty!(strat.orders)
    for inst in strat.universe.data.instance
        empty!(inst.orders)
    end
end
@doc "Reloads ohlcv data for assets already present in the strategy universe."
reload!(strat::Strategy) = begin
    for inst in strat.universe.data.instance
        empty!(inst.data)
        load!(inst; reset=true)
    end
end

process(::Strategy, date::DateTime, orders::Vector{LiveOrder}) = Order((Buy, 0))
assets(::Strategy, e::ExchangeID=nothing) = Asset[]
get_pairs(::Strategy) = String[]

macro notfound(path)
    quote
        throw(LoadError("Strategy not found at $(esc(file))"))
    end
end

function find_path(file, cfg)
    if !ispath(file)
        if isabspath(file)
            @notfound file
        else
            from_pwd = joinpath(pwd(), file)
            ispath(from_pwd) && return from_pwd
            from_cfg = joinpath(dirname(cfg.path), file)
            ispath(from_cfg) && return from_cfg
            from_proj = joinpath(dirname(Pkg.project().path), file)
            ispath(from_proj) && return from_proj
            @notfound file
        end
    end
    realpath(file)
end

function loadstrategy!(src::Symbol, cfg=config)
    file = get(cfg.sources, src, nothing)
    if isnothing(file)
        throw(KeyError("Symbol $src not found in config $(config.path)."))
    end
    path = find_path(file, cfg)
    mod = @eval begin
        include($path)
        using .$src: $src
        if isdefined(Main, :Revise)
            Core.eval(Main, :(Revise.track($$src)))
        end
        $src
    end
    # The strategy can have a default exchange symbol
    if cfg.exchange == Symbol()
        cfg.exchange = mod.exc
    end
    @assert isdefined(mod, :name) && mod.name isa Symbol "Source $src does not define a strategy name."
    pairs = Base.invokelatest(mod.get_pairs, Strategy{mod.name})
    Strategy(mod.name, pairs, cfg)
end

Base.display(strat::Strategy) = begin
    out = IOBuffer()
    try
        write(out, "Strategy name: $(typeof(strat))\n")
        write(out, "Base Amount: $(strat.config.base_amount)\n")
        write(out, "Universe:\n")
        write(out, string(Collections.prettydf(strat.universe)))
        write(out, "\n")
        write(out, "Balances:\n")
        write(out, string(strat.balances))
        write(out, "\n")
        write(out, "Orders:\n")
        write(out, string(strat.orders))
        Base.print(String(take!(out)))
    finally
        close(out)
    end
end

export Strategy, loadstrategy!, process, assets

end
