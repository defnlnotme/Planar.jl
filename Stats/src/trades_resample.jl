using Engine: DFT
using Engine.OrderTypes: Order
using Lang: fromstruct

# Use a generic Order instead to avoid the dataframe creating a too concrete order vector
TradesTuple1 = NamedTuple{
    (:date, :amount, :price, :value, :fees, :size, :leverage, :order),
    Tuple{collect(Vector{T} for T in (DateTime, DFT, DFT, DFT, DFT, DFT, DFT, Order))...},
}
function _tradesdf(trades::AbstractVector)
    tt = TradesTuple1(T[] for T in fieldtypes(TradesTuple1))
    df = DataFrame(tt)
    append!(df, trades)
    rename!(df, :date => :timestamp)
    df
end
function _tradesdf(ai::AssetInstance, from=firstindex(ai.history), to=lastindex(ai.history))
    length(from:to) < 1 || length(s.history) == 0 && return nothing
    _tradesdf(@view ai.history[from:to])
end
tradesdf(ai) = _tradesdf(ai.history)

isbuyorder(::Order{<:OrderType{S}}) where {S<:OrderSide} = S == Buy
issellorder(::Order{<:OrderType{S}}) where {S<:OrderSide} = S == Sell
buysell(g) = (buys=count(x -> x < 0, g), sells=count(x -> x > 0, g))
function transforms(style, custom)
    base = Any[
        :timestamp => first,
        :quote_volume => sum => :quote_balance,
        :base_volume => sum => :base_balance,
    ]
    if style == :full
        append!(
            base,
            (
                :base_volume => x -> sum(abs.(x)),
                :quote_volume => x -> sum(abs.(x)),
                :timestamp => length => :trades_count,
                :quote_volume => buysell => [:buys, :sells],
                # :order => tuple,
            ),
        )
    end
    append!(base, custom)
    base
end

@doc "Buys substract quote currency, while sells subtract base currency"
function tradesvolume!(data)
    data[!, :quote_volume] = data.size
    data[!, :base_volume] = data.amount
    let buymask = isbuyorder.(data.order), sellmask = xor.(buymask, true)
        data[sellmask, :base_volume] = -data.base_volume[sellmask]
        data[buymask, :quote_volume] = -data.quote_volume[buymask]
    end
end

function bydate(data, tf, tags...; sort=false)
    td = timefloat(tf)
    data[!, :sample] = timefloat.(data.timestamp) .÷ td
    groupby(data, [tags..., :sample]; sort)
end

function applytimeframe!(df, tf)
    select!(df, Not(:sample))
    df.timestamp[:] = apply.(tf, df.timestamp)
    df
end

@doc "Resamples trades data from a smaller to a higher timeframe."
function resample_trades(ai::AssetInstance, to_tf; style=:full, custom=())
    data = tradesdf(ai)
    isnothing(data) && return nothing
    tradesvolume!(data)
    gb = bydate(data, to_tf)
    df = combine(gb, transforms(style, custom)...; renamecols=false)
    applytimeframe!(df, to_tf)
end

# @doc "Converts a trade to a named tuple with its symbol as :name attribute."
# function namedtrade(name, trade)
#     NamedTuple((
#         :name => name, (p => getproperty(trade, p) for p in propertynames(trade))...
#     ))
# end
#

function expand(df, tf=timeframe!(df))
    df = outerjoin(
        DataFrame(:timestamp => collect(DateTime, daterange(df, tf))), df; on=:timestamp
    )
    sort!(df, :timestamp)
end

@doc """ Aggregates all trades of a strategy in a single dataframe

`byinstance`: `(trades_df, ai) -> nothing` can modify the dataframe of a single instance before it is appended
to the full df.
"""
function resample_trades(
    s::Strategy,
    tf=tf"1d";
    style=:full,
    byinstance=Returns(nothing),
    custom=(),
    expand_dates=false,
)
    df = DataFrame()
    for ai in s.universe
        isempty(ai.history) && continue
        tdf = tradesdf(ai)
        tdf[!, :instance] .= ai
        byinstance(tdf, ai)
        append!(df, tdf)
    end
    isempty(df) && return nothing
    tradesvolume!(df)
    # Group by instance because we need to calc value for each one separately
    gb = bydate(df, tf, :instance)
    df = combine(
        gb, transforms(style, (:instance => first, custom...))...; renamecols=false
    )
    applytimeframe!(df, tf)
    expand_dates ? expand(df, tf) : sort!(df, :timestamp)
end

export tradesdf, resample_trades
