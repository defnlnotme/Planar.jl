using .Checks: sanitize_price, sanitize_amount
using .Checks: iscost, ismonotonic, SanitizeOff, cost, withfees
using .Strategies: PriceTime
using .Instances:
    MarginInstance, NoMarginInstance, AssetInstance, @rprice, @ramount, amount_with_fees
using .OrderTypes:
    IncreaseOrder, ShortBuyOrder, LimitOrderType, MarketOrderType, PostOnlyOrderType
using .OrderTypes: ExchangeID, ByPos, ordertype
using .Instruments: AbstractAsset
using Base: negate, beginsym
using .Lang: @lget!, @deassert
using .Misc: Long, Short, PositionSide

@doc """ Type alias for any limit order """
const AnyLimitOrder{S<:OrderSide,P<:PositionSide} = Order{
    <:LimitOrderType{S},<:AbstractAsset,<:ExchangeID,P
}

@doc """ Type alias for any GTC order """
const AnyGTCOrder = Union{GTCOrder,ShortGTCOrder}

@doc """ Type alias for any FOK order """
const AnyFOKOrder = Union{FOKOrder,ShortFOKOrder}

@doc """ Type alias for any IOC order """
const AnyIOCOrder = Union{IOCOrder,ShortIOCOrder}

@doc """ Type alias for any market order """
const AnyMarketOrder{S<:OrderSide,P<:PositionSide} = Order{
    <:MarketOrderType{S},<:AbstractAsset,<:ExchangeID,P
}

@doc """ Type alias for any post only order """
const AnyPostOnlyOrder{S<:OrderSide,P<:PositionSide} = Order{
    <:PostOnlyOrderType{S},<:AbstractAsset,<:ExchangeID,P
}

@doc """
Clamps the given values within the correct boundaries.

$(TYPEDSIGNATURES)
"""
function _doclamp(clamper, ai, whats...)
    ai = esc(ai)
    clamper = esc(clamper)
    expr = quote end
    for w in whats
        w = esc(w)
        push!(expr.args, :(isnothing($w) || begin
            $w = $clamper($ai, $w)
        end))
    end
    expr
end

@doc """
Ensures the price is within correct boundaries.

$(TYPEDSIGNATURES)
"""
macro price!(ai, prices...)
    _doclamp(:($(@__MODULE__).sanitize_price), ai, prices...)
end

@doc """
Ensures the amount is within correct boundaries.

$(TYPEDSIGNATURES)
"""
macro amount!(ai, amounts...)
    _doclamp(:($(@__MODULE__).sanitize_amount), ai, amounts...)
end

@doc """
Calculates the commitment for an increase order without margin.

$(TYPEDSIGNATURES)
"""
function committment(
    ::Type{<:IncreaseOrder}, ai::NoMarginInstance, price, amount; kwargs...
)
    @deassert amount > 0.0
    withfees(cost(price, amount), maxfees(ai), IncreaseOrder)
end

@doc """
Calculates the commitment for a leveraged position.

$(TYPEDSIGNATURES)
"""
function committment(
    o::Type{<:IncreaseOrder},
    ai::MarginInstance,
    price,
    amount;
    ntl=cost(price, amount),
    fees=ntl * maxfees(ai),
    lev=leverage(ai, positionside(o)()),
    kwargs...,
)
    @deassert amount > 0.0
    margin = ntl / lev
    margin + fees
end

@doc """
Calculates the commitment when exiting a position for longs.

$(TYPEDSIGNATURES)
"""
function committment(::Type{<:SellOrder}, ai, price, amount; fees_base=ZERO, kwargs...)
    @deassert amount > 0.0
    amount_with_fees(amount, fees_base)
end

@doc """
Calculates the commitment when exiting a position for shorts.

$(TYPEDSIGNATURES)
"""
function committment(::Type{<:ShortBuyOrder}, ai, price, amount; fees_base=ZERO, kwargs...)
    @deassert amount > 0.0
    amount_with_fees(negate(amount), fees_base)
end

@doc """
Calculates the partial commitment of a trade.

$(TYPEDSIGNATURES)
"""
function committment(ai::AssetInstance, t::Trade)
    o = t.order
    committment(
        typeof(o), ai, o.price, t.amount; t.fees_base, t.fees, ntl=t.value, lev=t.leverage
    )
end

@doc """
Calculates the commitment for an order.

$(TYPEDSIGNATURES)
"""
function committment(ai::AssetInstance, o::Order; kwargs...)
    committment(typeof(o), ai, o.price, o.amount; kwargs...)
end

@doc """
Calculates the unfulfilled amount for a buy order.

$(TYPEDSIGNATURES)
"""
function unfillment(t::Type{<:AnyBuyOrder}, amount)
    @deassert amount > 0.0
    @deassert !(t isa AnySellOrder)
    negate(amount)
end

@doc """
Calculates the unfulfilled amount for a sell order.

$(TYPEDSIGNATURES)
"""
function unfillment(t::Type{<:AnySellOrder}, amount)
    @deassert amount > 0.0
    @deassert !(t isa AnyBuyOrder)
    amount
end

@doc """
Calculates the unfulfilled amount for an order.

$(TYPEDSIGNATURES)
"""
unfillment(o::Order) = unfillment(typeof(o), o.amount)

@doc """
Checks if a strategy can commit to an increase order.

$(TYPEDSIGNATURES)
"""
function iscommittable(s::Strategy, ::Type{<:IncreaseOrder}, commit, ai)
    @deassert st.freecash(s) |> gtxzero
    c = st.freecash(s)
    comm = commit[]
    c >= comm || isapprox(c, comm)
end

@doc """
Checks if a strategy can commit to a sell order.

$(TYPEDSIGNATURES)
"""
function iscommittable(s::Strategy, ::Type{<:SellOrder}, commit, ai)
    @deassert Instances.freecash(ai, Long()) |> gtxzero
    @deassert commit[] |> gtxzero
    c = Instances.freecash(ai, Long())
    comm = commit[]
    c >= comm || isapprox(c, comm)
end

@doc """
Checks if a strategy can commit to a short buy order.

$(TYPEDSIGNATURES)
"""
function iscommittable(::Strategy, ::Type{<:ShortBuyOrder}, commit, ai)
    @deassert Instances.freecash(ai, Short()) |> ltxzero
    @deassert commit[] |> ltxzero
    c = Instances.freecash(ai, Short())
    comm = commit[]
    c <= comm || isapprox(c, comm)
end

@doc """
Iterates over all the orders in a strategy.

$(TYPEDSIGNATURES)
"""
function orders(s::Strategy)
    OrderIterator((orders(s, ai, side) for side in (Buy, Sell) for ai in s.holdings))
end

@doc """
Iterates over all the orderless orders in a strategy.

$(TYPEDSIGNATURES)
"""
function orders(s::Strategy, ::Val{:orderless})
    (o for side in (Buy, Sell) for ai in s.holdings for o in orders(s, ai, side))
end

@doc """
Iterates over all the orders for an asset instance in a strategy.

$(TYPEDSIGNATURES)
"""
function orders(s::Strategy, ai::AssetInstance)
    buys = orders(s, ai, Buy)
    if length(buys) == 0
        orders(s, ai, Sell)
    else
        sells = orders(s, ai, Sell)
        if length(sells) == 0
            buys
        else
            OrderIterator(buys, sells)
        end
    end
end

@doc """
Iterates over all the orderless orders for an asset instance in a strategy.

$(TYPEDSIGNATURES)
"""
function orders(s::Strategy, ai::AssetInstance, ::Val{:orderless})
    (o for side in (Buy, Sell) for o in orders(s, ai, side))
end

@doc """
Returns all orders for an asset instance in a strategy.

$(TYPEDSIGNATURES)
"""
orders(s, ai, ::Type{Both}) = orders(s, ai)

@doc """
Returns all buy orders for a strategy.

$(TYPEDSIGNATURES)
"""
orders(s::Strategy, ::BySide{Buy}) = getfield(s, :buyorders)

@doc """
Returns all sell orders for a strategy.

$(TYPEDSIGNATURES)
"""
orders(s::Strategy, ::BySide{Sell}) = getfield(s, :sellorders)

@doc """
Returns all buy orders for an asset in a strategy.

$(TYPEDSIGNATURES)
"""
function orders(s::Strategy{M,S,E}, ai, ::BySide{Buy}) where {M,S,E}
    @lget! s.buyorders ai st.BuyOrdersDict{E}(st.BuyPriceTimeOrdering())
end

@doc """
Returns all sell orders for an asset in a strategy.

$(TYPEDSIGNATURES)
"""
function orders(s::Strategy{M,S,E}, ai, ::BySide{Sell}) where {M,S,E}
    @lget! s.sellorders ai st.SellOrdersDict{E}(st.SellPriceTimeOrdering())
end

@doc """
Returns all keys for orders in a strategy.

$(TYPEDSIGNATURES)
"""
Base.keys(s::Strategy, args...; kwargs...) = (k for (k, _) in orders(s, args...; kwargs...))

@doc """
Returns all values for orders in a strategy.

$(TYPEDSIGNATURES)
"""
function Base.values(s::Strategy, args...; kwargs...)
    (o for (_, o) in orders(s, args...; kwargs...))
end

@doc """
Returns the first order for an asset in a strategy.

$(TYPEDSIGNATURES)
"""
function Base.first(s::Strategy{M,S,E}, ai, bs::BySide=Both) where {M,S,E}
    values(s, ai, bs) |> first
end

@doc """
Returns the first index for an order for an asset in a strategy.

$(TYPEDSIGNATURES)
"""
function Base.firstindex(s::Strategy{M,S,E}, ai, bs::BySide=Both) where {M,S,E}
    keys(s, ai, bs) |> first
end

@doc """
Returns the last order for an asset in a strategy.

$(TYPEDSIGNATURES)
"""
function Base.last(s::Strategy{M,S,E}, ai, bs::BySide=Both) where {M,S,E}
    ans = missing
    for v in values(s, ai, bs)
        ans = v
    end
    ismissing(ans) && throw(BoundsError())
    ans
end

@doc """
Returns the last index for an order for an asset in a strategy.

$(TYPEDSIGNATURES)
"""
function Base.lastindex(s::Strategy{M,S,E}, ai, bs::BySide=Both) where {M,S,E}
    ans = missing
    for k in keys(s, ai, bs)
        ans = k
    end
    ismissing(ans) && throw(BoundsError())
    ans
end

@doc """
Returns the count of orders in a strategy.

$(TYPEDSIGNATURES)
"""
function orderscount(s::Strategy, ::BySide{O}) where {O}
    ans = 0
    for v in values(orders(s, O))
        ans += length(v)
    end
    ans
end

@doc """
Returns the count of pending entry orders in a strategy.

$(TYPEDSIGNATURES)
"""
function orderscount(s::Strategy, ::Val{:increase})
    ans = 0
    for (_, o) in values(orders(s))
        if o isa IncreaseOrder
            ans += 1
        end
    end
    ans
end

@doc """
Returns the count of pending exit orders in a strategy.

$(TYPEDSIGNATURES)
"""
function orderscount(s::Strategy, ::Val{:reduce})
    ans = 0
    for (_, o) in values(orders(s))
        if o isa ReduceOrder
            ans += 1
        end
    end
    ans
end

@doc """
Returns the total count of pending orders in a strategy.

$(TYPEDSIGNATURES)
"""
function orderscount(s::Strategy)
    orderscount(s, Buy) + orderscount(s, Sell)
end

@doc """
Returns the count of orders for an asset in a strategy.

$(TYPEDSIGNATURES)
"""
function orderscount(s::Strategy, ai::AssetInstance)
    n = 0
    for _ in orders(s, ai)
        n += 1
    end
    n
end

@doc """
Returns the count of orders for an asset in a strategy.

$(TYPEDSIGNATURES)
"""
orderscount(s::Strategy, ai::AssetInstance, ::Type{Both}) = orderscount(s, ai)

@doc """
Returns the count of buy orders for an asset in a strategy.

$(TYPEDSIGNATURES)
"""
orderscount(s::Strategy, ai::AssetInstance, ::Type{Buy}) = length(buyorders(s, ai))

@doc """
Returns the count of sell orders for an asset in a strategy.

$(TYPEDSIGNATURES)
"""
orderscount(s::Strategy, ai::AssetInstance, ::Type{Sell}) = length(sellorders(s, ai))

@doc """Checks if any of the holdings has non dust cash.

$(TYPEDSIGNATURES)
"""
function hascash(s::Strategy)
    for ai in s.holdings
        iszero(ai) || return true
    end
    return false
end

@doc """
Checks if a strategy has orders.

$(TYPEDSIGNATURES)
"""
hasorders(s::Strategy) = orderscount(s) == 0

@doc """
Returns buy orders for an asset in a strategy.

$(TYPEDSIGNATURES)
"""
buyorders(s::Strategy, ai) = orders(s, ai, Buy)

@doc """
Returns sell orders for an asset in a strategy.

$(TYPEDSIGNATURES)
"""
sellorders(s::Strategy, ai) = orders(s, ai, Sell)

@doc """
Returns orders for an asset in a strategy by side.

$(TYPEDSIGNATURES)
"""
sideorders(s::Strategy, ai, ::Type{Buy}) = buyorders(s, ai)

@doc """
Returns orders for an asset in a strategy by side.

$(TYPEDSIGNATURES)
"""
sideorders(s::Strategy, ai, ::Type{Sell}) = sellorders(s, ai)

@doc """
Returns orders for an asset in a strategy by side.

$(TYPEDSIGNATURES)
"""
sideorders(s::Strategy, ai, ::BySide{S}) where {S} = sideorders(s, ai, S)

@doc """
Checks if an array has any elements.

$(TYPEDSIGNATURES)
"""
function _hasany(arr)
    n = 0
    for _ in arr
        n += 1
        break
    end
    n != 0
end

@doc """
Checks if an asset instance has pending buy orders in a strategy.

$(TYPEDSIGNATURES)
"""
hasorders(s::Strategy, ai, ::Type{Buy}) = _hasany(orders(s, ai, Buy))

@doc """
Checks if an asset instance has pending sell orders in a strategy.

$(TYPEDSIGNATURES)
"""
function hasorders(s::Strategy, ai, ::Type{Sell})
    !iszero(something(committed(ai), 0.0)) && _hasany(orders(s, ai, Sell))
end

@doc """
Checks if an asset instance has pending orders in a strategy.

$(TYPEDSIGNATURES)
"""
function hasorders(s::Strategy, ai::AssetInstance)
    (hasorders(s, ai, Sell) || hasorders(s, ai, Buy))
end

function hasorders(s::Strategy, ai::AssetInstance, ::Type{Both})
    hasorders(s, ai)
end

@doc """
Checks if an asset instance has a specific order in a strategy.

!!! warning "Not for sim mode"
    For speed reason we don't construct order ids (which are strings) in sim mode.

$(TYPEDSIGNATURES)
"""
hasorders(s::Strategy{<:Union{Paper,Live}}, ai, id::String) = begin
    for o in values(s, ai)
        o.id == id && return true
    end
    false
end

@doc """
Checks if an asset instance has a specific order in a strategy by side.

$(TYPEDSIGNATURES)
"""
function hasorders(s::Strategy, ai, id::String, ::BySide{S}) where {S<:OrderSide}
    for o in values(s, ai, S)
        o.id == id && return true
    end
    false
end

@doc """
Checks if a strategy has a specific order for an asset.

$(TYPEDSIGNATURES)
"""
Base.haskey(s::Strategy, ai, o::Order) = haskey(sideorders(s, ai, o), pricetime(o))

@doc """
Checks if a strategy has a specific order for an asset by price and time.

$(TYPEDSIGNATURES)
"""
function Base.haskey(s::Strategy, ai, pt::PriceTime, side::BySide{<:Union{Buy,Sell}})
    haskey(sideorders(s, ai, side), pt)
end

@doc """
Checks if a strategy has a specific order for an asset by price and time.

$(TYPEDSIGNATURES)
"""
function Base.haskey(s::Strategy, ai, pt::PriceTime, ::BySide{Both})
    haskey(sideorders(s, ai, Buy), pt) || haskey(sideorders(s, ai, Sell), pt)
end

@doc """
Checks if a strategy has a specific order for an asset by price and time.

$(TYPEDSIGNATURES)
"""
Base.haskey(s::Strategy, ai, pt::PriceTime) = haskey(s, ai, pt, Both)

@doc """
Checks if a strategy has buy orders.

$(TYPEDSIGNATURES)
"""
hasorders(s::Strategy, ::Type{Buy}) = !iszero(s.cash_committed)

@doc """
Checks if a strategy has sell orders.

$(TYPEDSIGNATURES)
"""
function hasorders(s::Strategy, ::Type{Sell})
    for (_, ords) in s.sellorders
        isempty(ords) || return true
    end
    return false
end

@doc """
Checks if a strategy is out of orders.

$(TYPEDSIGNATURES)
"""
function isoutof_orders(s::Strategy)
    ltxzero(s.cash) && isempty(s.holdings) && length(orderscount(s)) == 0
end

@doc """
Checks a buy trade.

$(TYPEDSIGNATURES)
"""
function _check_trade(t::BuyTrade, ai)
    @deassert t.price <= t.order.price || ordertype(t) <: MarketOrderType
    @deassert t.size < 0.0
    @deassert t.amount > 0.0
    @deassert gtxzero(ai, committed(t.order), Val(:price)) ||
        ordertype(t) <: MarketOrderType committed(t.order), t.order.attrs.trades
end

@doc """
Checks a sell trade.

$(TYPEDSIGNATURES)
"""
function _check_trade(t::SellTrade, ai)
    @deassert t.price >= t.order.price || ordertype(t) <: MarketOrderType (
        t.price, t.order.price
    )
    @deassert t.size > 0.0
    @deassert t.amount < 0.0
    @deassert committed(t.order) >= -1e-12
end

@doc """
Checks a short sell trade.

$(TYPEDSIGNATURES)
"""
function _check_trade(t::ShortSellTrade, ai)
    @deassert t.price >= t.order.price || ordertype(t) <: MarketOrderType
    @deassert t.size < 0.0
    @deassert t.amount < 0.0
    @deassert abs(committed(t.order)) <= t.fees || t.order isa ShortSellOrder
end

@doc """
Checks a short buy trade.

$(TYPEDSIGNATURES)
"""
function _check_trade(t::ShortBuyTrade, ai)
    @deassert t.price <= t.order.price || ordertype(t) <: MarketOrderType (
        t.price, t.order.price
    )
    @deassert t.size > 0.0
    @deassert t.amount > 0.0
    @deassert committed(t.order) |> ltxzero
end

@doc """
Checks the cash for an asset instance in a strategy for long.

$(TYPEDSIGNATURES)
"""
function _check_cash(ai::AssetInstance, ::Long)
    @deassert gtxzero(ai, committed(ai, Long()), Val(:amount)) ||
        ordertype(last(ai.history)) <: MarketOrderType committed(ai, Long()).value
    @deassert cash(ai, Long()) |> gtxzero
end

@doc """
Checks the cash for an asset instance in a strategy for short.

$(TYPEDSIGNATURES)
"""
_check_cash(ai::AssetInstance, ::Short) = begin
    @deassert committed(ai, Short()) |> ltxzero
    @deassert cash(ai, Short()) |> ltxzero
end

_cur_by_side(o::BuyOrder) = :fees_base
_cur_by_side(o::SellOrder) = :fees
@doc """
The sum of all the trades fees that have heppened for the order.

$(TYPEDSIGNATURES)
"""
function feespaid(o::Order)
    ot = trades(o)
    if isempty(ot)
        ZERO
    else
        cur = _cur_by_side(o)
        sum(getproperty(t, cur) for t in trades(o))
    end
end
