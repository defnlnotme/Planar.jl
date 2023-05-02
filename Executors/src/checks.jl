module Checks
using Lang: Option, @ifdebug
using Misc: isstrictlysorted, toprecision
using Instances
using Strategies: NoMarginStrategy, IsolatedStrategy
using OrderTypes
using Base: negate

struct SanitizeOn end
struct SanitizeOff end

@doc "The cost of a trade is always *absolute*. (while fees can also be negative.)"
cost(price, amount) = abs(price * amount)
@doc "When increasing a position fees are added to the currency spent."
function withfees(cost, fees, ::T) where {T<:Union{IncreaseOrder,Type{<:IncreaseOrder}}}
    muladd(cost, fees, cost)
end
@doc "When exiting a position fees are deducted from the received currency."
function withfees(cost, fees, ::T) where {T<:Union{ReduceOrder,Type{<:ReduceOrder}}}
    muladd(negate(cost), fees, cost)
end

checkprice(_::NoMarginStrategy, _, _, _) = nothing
@doc "The price of a trade for long positions should never be below the liquidation price."
function checkprice(_::IsolatedStrategy, ai, actual_price, ::LongOrder)
    @assert actual_price > liquidation(ai, Long)
end
@doc "The price of a trade for short positions should never be above the liquidation price."
function checkprice(_::IsolatedStrategy, ai, actual_price, ::ShortOrder)
    @assert actual_price < liquidation(ai, Short)
end
@doc "Amount changes sign only after trade creation, it is always given as *positive*."
checkamount(actual_amount) = @assert actual_amount >= 0.0

@doc """Price and amount value of an order are adjusted by subtraction.

Which means that their output values will always be lower than their input, **except** \
for the case in which their values would fall below the exchange minimums. In such case \
the exchange minimum is returned.
"""
function sanitize_amount(ai::AssetInstance, amount)
    if ai.limits.amount.min > 0 && amount < ai.limits.amount.min
        ai.limits.amount.min
    elseif ai.precision.amount < 0 # has to be a multiple of 10
        max(toprecision(Int(amount), 10), ai.limits.amount.min)
    else
        toprecision(amount, ai.precision.amount)
    end
end

@doc """ See `sanitize_amount`.
"""
function sanitize_price(ai::AssetInstance, price)
    if ai.limits.price.min > 0 && price < ai.limits.price.min
        ai.limits.price.min
    else
        max(toprecision(price, ai.precision.price), ai.limits.price.min)
    end
end

function _cost_msg(asset, direction, value, cost)
    "The cost ($cost) of the order ($asset) is $direction market minimum of $value"
end

function ismincost(ai::AssetInstance, price, amount)
    iszero(ai.limits.cost.min) || begin
        cost = price * amount
        cost >= ai.limits.cost.min
    end
end
@doc """ The cost of the order should not be below the minimum for the exchange.
"""
function checkmincost(ai::AssetInstance, price, amount)
    @assert ismincost(ai, price, amount) _cost_msg(
        ai.asset, "below", ai.limits.cost.min, price * amount
    )
    return true
end
function ismaxcost(ai::AssetInstance, price, amount)
    iszero(ai.limits.cost.max) || begin
        cost = price * amount
        cost < ai.limits.cost.max
    end
end
@doc """ The cost of the order should not be above the maximum for the exchange.
"""
function checkmaxcost(ai::AssetInstance, price, amount)
    @assert ismaxcost(ai, price, amount) _cost_msg(
        ai.asset, "above", ai.limits.cost.max, price * amount
    )
    return true
end

function _checkcost(fmin, fmax, ai::AssetInstance, amount, prices...)
    ok = false
    for p in Iterators.reverse(prices)
        isnothing(p) || (fmax(ai, amount, p) && (ok = true; break))
    end
    ok || return false
    ok = false
    for p in prices
        isnothing(p) || (fmin(ai, amount, p) && (ok = true; break))
    end
    ok
end

@doc """ Checks that the last price given is below maximum, and the first is above minimum.
In other words, it expects all given prices to be already sorted."""
function checkcost(ai::AssetInstance, amount, prices...)
    _checkcost(checkmincost, checkmaxcost, ai, amount, prices...)
end
function checkcost(ai::AssetInstance, amount, p1)
    checkmaxcost(ai, amount, p1)
    checkmincost(ai, amount, p1)
end
function iscost(ai::AssetInstance, amount, prices...)
    _checkcost(ismincost, ismaxcost, ai, amount, prices...)
    true
end
function iscost(ai::AssetInstance, amount, p1)
    ismaxcost(ai, amount, p1)
    ismincost(ai, amount, p1)
end

ismonotonic(prices...) = isstrictlysorted(Iterators.filter(!isnothing, prices)...)
@doc """ Checks that the given prices are sorted. """
function check_monotonic(prices...)
    @assert ismonotonic(prices...) "Prices should be sorted, e.g. stoploss < price < takeprofit"
    return true
end

export SanitizeOn, SanitizeOff, cost, withfees, checkprice, checkamount

end
