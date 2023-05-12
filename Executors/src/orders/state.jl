using Lang: @deassert, @lget!, Option
using OrderTypes
import OrderTypes: commit!, tradepos
using Strategies: Strategies as st, MarginStrategy, IsolatedStrategy
using Misc: Short
using Instruments
using Instruments: @importcash!
@importcash!

##  committed::Float64 # committed is `cost + fees` for buying or `amount` for selling
const _BasicOrderState{T} = NamedTuple{
    (:take, :stop, :committed, :unfilled, :trades),
    Tuple{Option{T},Option{T},Vector{T},Vector{T},Vector{Trade}},
}

function basic_order_state(
    take, stop, committed::Vector{T}, unfilled::Vector{T}, trades=Trade[]
) where {T<:Real}
    _BasicOrderState{T}((take, stop, committed, unfilled, trades))
end

@doc "Construct an `Order` for a given `OrderType` `type` and inputs."
function basicorder(
    ai::AssetInstance,
    price,
    amount,
    committed,
    ::SanitizeOff;
    type::Type{<:Order},
    date,
    take=nothing,
    stop=nothing,
)
    ismonotonic(stop, price, take) || return nothing
    iscost(ai, amount, stop, price, take) || return nothing
    @deassert if type <: AnyBuyOrder
        committed[] > ai.limits.cost.min
    else
        committed[] > ai.limits.amount.min
    end "Order committment too low\n$(committed[]), $(ai.asset) $date"
    let unfilled = unfillment(type, amount)
        @deassert type <: AnyBuyOrder ? unfilled[] < 0.0 : unfilled[] > 0.0
        OrderTypes.Order(
            ai,
            type;
            date,
            price,
            amount,
            attrs=basic_order_state(take, stop, committed, unfilled),
        )
    end
end

@doc "Remove a single order from the order queue."
function Base.delete!(s::Strategy, ai, o::IncreaseOrder)
    @deassert !(o isa MarketOrder) # Market Orders are never queued
    @deassert committed(o) >= -1e-12 committed(o)
    subzero!(s.cash_committed, committed(o))
    delete!(orders(s, ai, orderside(o)), pricetime(o))
end
function Base.delete!(s::Strategy, ai, o::SellOrder)
    @deassert committed(o) >= -1e-12 committed(o)
    sub!(committed(ai, Long()), committed(o))
    delete!(orders(s, ai, orderside(o)), pricetime(o))
    # If we don't have cash for this asset, it should be released from holdings
    release!(s, ai, o)
end
function Base.delete!(s::Strategy, ai, o::ShortBuyOrder)
    # Short buy orders have negative committment
    @deassert committed(o) <= 0.0 committed(o)
    @deassert committed(ai, Short()) <= 0.0
    add!(committed(ai, Short()), committed(o))
    delete!(orders(s, ai, Buy), pricetime(o))
    # If we don't have cash for this asset, it should be released from holdings
    release!(s, ai, o)
end
@doc "Remove all buy/sell orders for an asset instance."
function Base.delete!(s::Strategy, ai, t::Type{<:Union{Buy,Sell}})
    delete!.(s, ai, values(orders(s, ai, t)))
end
Base.delete!(s::Strategy, ai, ::Type{Both}) = begin
    delete!(s, ai, Buy)
    delete!(s, ai, Sell)
end
Base.delete!(s::Strategy, ai) = delete!(s, ai, Both)
@doc "Inserts an order into the order dict of the asset instance. Orders should be identifiable by a unique (price, date) tuple."
function Base.push!(s::Strategy, ai, o::Order{<:OrderType{S}}) where {S<:OrderSide}
    let k = pricetime(o), d = orders(s, ai, S) #, stok = searchsortedfirst(d, k)
        @assert k ∉ keys(d) "Orders with same price and date are not allowed."
        d[k] = o
    end
end

# NOTE: unfilled is always negative
function fill!(o::IncreaseOrder, t::IncreaseTrade)
    @deassert o isa IncreaseOrder && attr(o, :unfilled)[] <= 0.0
    @deassert committed(o) == o.attrs.committed[] && committed(o) >= 0.0
    attr(o, :unfilled)[] += t.amount # from neg to 0 (buy amount is pos)
    @deassert attr(o, :unfilled)[] <= 1e-14
    attr(o, :committed)[] += t.size # from pos to 0 (buy size is neg)
    @deassert committed(o) >= 0.0
end
function fill!(o::SellOrder, t::SellTrade)
    @deassert o isa SellOrder && attr(o, :unfilled)[] >= 0.0
    @deassert committed(o) == o.attrs.committed[] && committed(o) >= 0.0
    attr(o, :unfilled)[] += t.amount # from pos to 0 (sell amount is neg)
    @deassert attr(o, :unfilled)[] >= -1e-12
    attr(o, :committed)[] += t.amount # from pos to 0 (sell amount is neg)
    @deassert committed(o) >= -1e-12
end
function fill!(o::ShortBuyOrder, t::ShortBuyTrade)
    @deassert o isa ShortBuyOrder && attr(o, :unfilled)[] >= 0.0
    @deassert committed(o) == o.attrs.committed[] && committed(o) >= 0.0
    @deassert attr(o, :unfilled)[] < 0.0
    attr(o, :unfilled)[] += t.amount # from pos to 0 (sell amount is neg)
    @deassert attr(o, :unfilled)[] >= 0
    # NOTE: committment is always positive so in case of reducing short in buy, we have to subtract
    attr(o, :committed)[] -= t.amount # from pos to 0 (sell amount is neg)
    @deassert committed(o) >= 0.0
end

isfilled(ai::AssetInstance, o::Order) = iszero(ai, attr(o, :unfilled)[])
Base.isopen(ai::AssetInstance, o::Order) = !isfilled(ai, o)

function cash!(s::Strategy, ai, t::Trade)
    @ifdebug _check_trade(t)
    cash!(s, t)
    cash!(ai, t)
    @ifdebug _check_cash(ai, tradepos(t)())
end

attr(o::Order, sym) = getfield(getfield(o, :attrs), sym)
unfilled(o::Order) = abs(attr(o, :unfilled)[])

commit!(s::Strategy, o::IncreaseOrder, _) = add!(s.cash_committed, committed(o))
commit!(::Strategy, o::ReduceOrder, ai) = add!(committed(ai, orderpos(o)()), committed(o))
iscommittable(s::Strategy, o::IncreaseOrder, _) = begin
    @deassert committed(o) > 0.0
    st.freecash(s) >= committed(o)
end
function iscommittable(::Strategy, o::SellOrder, ai)
    @deassert committed(o) > 0.0
    Instances.freecash(ai, Long()) >= committed(o)
end
function iscommittable(::Strategy, o::ShortBuyOrder, ai)
    @deassert committed(o) < 0.0
    Instances.freecash(ai, Short()) <= committed(o)
end

hold!(s::Strategy, ai, ::IncreaseOrder) = push!(s.holdings, ai)
hold!(::Strategy, _, ::ReduceOrder) = nothing
release!(::Strategy, _, ::IncreaseOrder) = nothing
function release!(s::Strategy, ai, o::ReduceOrder)
    iszero(cash(ai, orderpos(o)())) && pop!(s.holdings, ai)
end
@doc "Cancel an order with given error."
function cancel!(s::Strategy, o::Order, ai; err::OrderError)
    delete!(s, ai, o)
    st.ping!(s, o, err, ai)
end

amount(o::Order) = getfield(o, :amount)
committed(o::Order) = begin
    @deassert attr(o, :committed)[] >= -1e-12
    attr(o, :committed)[]
end
