using .Executors: _cashfrom, hasorders, decommit!, aftertrade!

maxout!(s::LiveStrategy) = begin
    # strategy
    v = s.cash.value
    cash!(s.cash, typemax(v))
    cash!(s.cash_committed, zero(v))
end

@doc """ Maximizes cash and neutralizes commitments before syncing.

$(TYPEDSIGNATURES)

Before syncing orders, this function sets the cash value of both the strategy and asset instance to its maximum and commits cash to zero. This prevents order creation from failing due to insufficient funds.

"""
maxout!(s::LiveStrategy, ai; skip_strategy=false) = begin
    # strategy
    if !skip_strategy
        maxout!(s)
    end
    if ai isa MarginInstance
        # Asset Long
        c = cash(ai, Long())
        cm = committed(ai, Long())
        cash!(c, typemax(c.value))
        cash!(cm, zero(c.value))
        # Asset Short
        c = cash(ai, Short())
        cm = committed(ai, Short())
        cash!(c, typemin(c.value))
        cash!(cm, zero(c.value))
    else
        c = cash(ai)
        cm = committed(ai)
        cash!(c, typemax(c.value))
        cash!(cm, zero(c.value))
    end
end

function replay_open_orders!(
    s,
    ai;
    waitfor,
    open_orders,
    exec,
    live_orders,
    eid,
    ao,
    side,
    default_pos,
    create_kwargs,
    overwrite,
)
    @timeout_start
    ids = Set{String}()
    events = get_events(ai)
    for resp in open_orders
        if resp_event_type(resp, eid) != ot.Order
            continue
        end
        id = resp_order_id(resp, eid, String)
        if !(id isa String) || isempty(id)
            continue
        end
        push!(ids, id)
        function func()
            o = (@something let state = get(ao, id, nothing)
                if state isa LiveOrderState
                    state.order
                end
            end findorder(s, ai; id, side, resp) _create_live_order(
                s,
                ai,
                resp;
                t=_ccxtposside(s, resp, eid; def=default_pos),
                price=missing,
                amount=missing,
                synced=false,
                skipcommit=(!overwrite),
                withoutkws(:skipcommit; kwargs=create_kwargs)...,
                tag="replay_open",
            ) missing)::Union{Nothing,<:Order,Missing}
            if ismissing(o)
                pop!(ids, id)
                return nothing
            elseif isfilled(ai, o)
                trades_amount = _amount_from_trades(trades(o)) |> abs
                if !isequal(ai, trades_amount, o.amount, Val(:amount))
                    @warn "sync orders: replaying filled order with no trades" _module =
                        LogSyncOrder
                    # we decommit when orders are already present (sync is called mid run)
                    replay_order!(s, o, ai; resp, exec=false, decommit=!overwrite)
                else
                    @debug "sync orders: removing filled active order" _module =
                        LogSyncOrder o.id o.amount trades_amount ai s = nameof(s)
                    clear_order!(s, ai, o)
                end
            else
                @debug "sync orders: setting active order" _module = LogSyncOrder o.id ai s = nameof(
                    s
                )
                push!(live_orders, o.id)
                replay_order!(s, o, ai; resp, exec, decommit=!overwrite)
            end
            pop!(ids, id)
        end
        date = @something resp_order_timestamp(resp, eid) timestamp(ai)
        sendrequest!(ai, date, func; events)
    end
    waitforcond(() -> isempty(ids), @timeout_now())
end

@doc "Removes stale local orders"
function remove_local_orders(s, ai; overwrite, eid, open_orders, side)
    # Pre-delete local orders not open on exc to fix strategy cash commit calculation
    exc_ids = Set(resp_order_id(resp, eid) for resp in open_orders)
    for o in values(s, ai, side)
        if o.id ∉ exc_ids
            if !overwrite
                decommit!(s, o, ai)
            end
            delete!(s, ai, o)
        end
    end
end

function remove_live_orders(s, ai; overwrite, live_orders, side)
    for o in values(s, ai, side)
        if o.id ∉ live_orders
            @debug "sync orders: local order non open on exchange." _module = LogSyncOrder o.id ai exchange(
                ai
            )
            if !overwrite
                decommit!(s, o, ai)
            end
            delete!(s, ai, o)
        end
    end
end

"""
Synchronizes open orders with the live trading environment.

$(TYPEDSIGNATURES)

This function syncs the live open orders with the trading strategy and asset instance provided.
It fetches open orders, replays them, and updates the order tracking.
This function also handles checking and updating of cash commitments for the strategy and asset instance.

Args:
    s (LiveStrategy): The live trading strategy.
    ai: The asset instance.
    live_orders (Set{String}): The set of live order IDs.
    ao (Dict{String, OrderState}): The dictionary of active orders.
    side (BuyOrSell): The side of the order.
    eid (String): The exchange ID.
    exec (bool): A boolean flag indicating whether to execute the orders during syncing.
"""
function sync_active_orders!(s, ai; live_orders, ao, side, eid, exec)
    @sync for (id, state) in ao
        if orderside(state.order) != side
            continue
        end
        if id ∉ live_orders
            @warn "sync orders: tracked local order was not open on exchange" ai id
            @deassert LogSyncOrder id == state.order.id
            if isopen(ai, state.order) # need to sync trades
                order_resp = try
                    resp = fetch_orders(s, ai; ids=(id,))
                    if islist(resp) && !isempty(resp)
                        first(resp)
                    elseif isdict(resp)
                        resp
                    end
                catch
                    @debug_backtrace LogSyncOrder
                end
                if isdict(order_resp)
                    @deassert LogSyncOrder resp_order_id(order_resp, eid, String) == id
                    replay_order!(s, state.order, ai; resp=order_resp, exec, decommit=true)
                elseif !iszero(filled_amount(state.order))
                    @error "sync orders: local order not found on exchange" id ai exchange(
                        ai
                    ) order_resp
                else
                    @debug "sync order: local order not found on exchange (probably canceled/rejected)" id ai exchange(
                        ai
                    ) order_resp
                end
                clear_order!(s, ai, state.order)
            else
                clear_order!(s, ai, state.order)
            end
        end
    end
end

function _overwrite_cash!(s, ai)
    @debug "sync orders: resyncing strategy balances." maxlog = 1 _module = LogSyncOrder
    if ai isa MarginInstance
        _live_sync_cash!(s, ai, Long(); overwrite=true)
        _live_sync_cash!(s, ai, Short(); overwrite=true)
    else
        _live_sync_cash!(s, ai; overwrite=true)
    end
    _live_sync_strategy_cash!(s; overwrite=true)
end

_amount_from_trades(trades) = sum(t.amount for t in trades)

@doc """ Synchronizes open orders with the live trading environment.

$(TYPEDSIGNATURES)

This function syncs the live open orders with the trading strategy and asset instance provided.
It fetches open orders, replay them, and updates the order tracking.
This function also handles checking and updating of cash commitments for the strategy and asset instance.

- `overwrite`: A boolean flag indicating whether to overwrite strategy state (default is `false`).
- `exec`: A boolean flag indicating whether to execute the orders during syncing (default is `false`).
- `create_kwargs`: A dictionary of keyword arguments for creating an order (default is `(;)`).
- `side`: The side of the order (default is `BuyOrSell`).

"""
function _live_sync_open_orders!(
    s::LiveStrategy,
    ai;
    waitfor=Second(15),
    overwrite=false,
    exec=false,
    create_kwargs=(;),
    side=BuyOrSell,
    raise=true,
)
    @timeout_start
    # Get active orders for the given strategy and asset instance
    ao = active_orders(ai)
    eid = exchangeid(ai)

    # Fetch open orders from the exchange
    open_orders = fetch_open_orders(s, ai; side)
    if isnothing(open_orders)
        msg = "sync orders: couldn't fetch open orders, skipping sync"
        if raise
            error(msg)
        else
            @error msg ai s = nameof(s)
            return nothing
        end
    end

    # Remove local orders that are not active on the exchange
    remove_local_orders(s, ai; overwrite, eid, open_orders, side)

    # Initialize a set to store live order IDs
    live_orders = Set{String}()

    # Debug logging for initial cash and committed amounts
    @ifdebug begin
        cash_long = cash(ai, Long())
        comm_long = committed(ai, Long())
        cash_short = cash(ai, Short())
        comm_short = committed(ai, Short())
    end

    @debug "sync orders: syncing" _module = LogSyncOrder ai islocked(ai) length(open_orders)

    # Lock the asset instance to prevent concurrent modifications
    default_pos = get_position_side(s, ai)

    # Reset cash state if overwrite is true
    if overwrite
        maxout!(s, ai)
    end

    # Replay open orders and update local state
    replay_open_orders!(
        s,
        ai;
        waitfor,
        open_orders,
        exec,
        live_orders,
        eid,
        ao,
        side,
        default_pos,
        create_kwargs,
        overwrite,
    )

    # FIXME: this check might not be needed anymore
    # Remove orders that are no longer live
    remove_live_orders(s, ai; overwrite, live_orders, side)

    # Process remaining orders
    sync_active_orders!(s, ai; live_orders, ao, side, eid, exec)

    # Verify that the number of orders matches the live orders set
    @deassert orderscount(s, ai, side) == length(live_orders)

    # Start trade and order watchers if there are active orders
    if orderscount(s, ai, side) > 0
        watch_trades!(s, ai) # ensure trade watcher is running
        watch_orders!(s, ai) # ensure orders watcher is running
    end

    # Debug assertion to check if cash and committed amounts remain unchanged (unless overwrite is true)
    @ifdebug @assert overwrite || all((
        cash_long == cash(ai, Long()),
        comm_long == committed(ai, Long()),
        cash_short == cash(ai, Short()),
        comm_short == committed(ai, Short()),
    ))

    # Overwrite cash state if specified
    if overwrite
        _overwrite_cash!(s, ai)
    end

    @debug "sync orders: done" _module = LogSyncOrder ai
    nothing
end

@doc """ Finds an order by id in a given side of the market.

$(TYPEDSIGNATURES)

The function searches for the order in live orders and then in trades history. If the id is empty or order not found, it returns nothing.

"""
function findorder(
    s,
    ai;
    resp=nothing,
    id=resp_order_id(resp, exchangeid(ai), String),
    side=if isnothing(resp)
        BuyOrSell
    else
        _ccxt_sidetype(resp, exchangeid(ai); getter=resp_order_side, def=BuyOrSell)
    end,
)
    if !isempty(id)
        for o in values(s, ai, side)
            if o.id == id
                @deassert o isa Order
                return o
            end
        end
        history = trades(ai)
        t = findfirst((t -> t.order.id == id), history)
        if t isa Integer
            return history[t].order
        else
            @debug "find order: not found" _module = LogEvents resp id t f = @caller
        end
    end
end

@doc "Find order from asset instance trades history.
`property`: if set, returns the matching order property."
function findorder(ai::AssetInstance, id; property=missing)
    for t in trades(ai)
        if t.order.id == id
            o = t.order
            return ismissing(property) ? o : getproperty(o, property)
        end
    end
    return nothing
end

@doc """ Replays an order from a live strategy based on a response.

$(TYPEDSIGNATURES)

This function checks if the order has been filled, and if it hasn't, it resets the order and returns.
If the order is filled, the function fetches its trades from the order struct or an API call, validates the trades, and applies new trades if necessary.
If there are no new trades, it emulates a trade.
The flag 'exec' determines whether the trades are executed or simply made.
The 'decommit' flag controls whether the trades are added to the asset's trade history.
"""
function replay_order!(s::LiveStrategy, o, ai; resp, exec=false, decommit=false)
    eid = exchangeid(ai)
    @debug "replay order: activate" _module = LogSyncOrder id = o.id ai
    state = set_active_order!(s, ai, o; ap=resp_order_average(resp, eid))
    if iszero(resp_order_filled(resp, eid))
        if !iszero(filled_amount(o))
            @warn "replay order: unexpected order state (resetting order)"
            reset!(o, ai)
        end
        if !hasorders(s, ai, o.id)
            queue!(s, o, ai)
        end
        @debug "replay order: order unfilled (returning)" _module = LogSyncOrder
        return o
    end
    if ismissing(state)
        @error "replay order: order state not found"
        return o
    end
    local_trades = trades(o)
    local_count = length(local_trades)
    # Try to get order trades from order struct first
    # otherwise from api call
    order_trades = let otr = resp_order_trades(resp, eid)
        if isempty(otr)
            otr = fetch_order_trades(s, ai, o.id)
        else
            otr
        end |> PyList
    end
    # Sanity check between local and exc trades by
    # comparing the amount of the first trade
    if length(order_trades) > 0 && local_count > 0
        trade = first(order_trades)
        local_amt = abs(first(trades(o)).amount)
        resp_amt = resp_trade_amount(trade, eid)
        # When a mismatch happens we reset local state for the order
        if isequal(ai, local_amt, resp_amt, Val(:amount))
            @warn "replay order: mismatching amounts (resetting)" local_amt resp_amt o.id ai exchange(
                ai
            )
            local_count = 0
            # remove trades from asset trades history
            filter!(t -> t.order !== o, trades(ai))
            # reset order
            reset!(o, ai)
        end
    end
    new_trades = @view order_trades[(begin + local_count):end]
    if isempty(new_trades)
        @debug "replay order: emulating trade" _module = LogSyncOrder
        trade = emulate_trade!(s, o, ai; state.average_price, resp, exec)
        if !exec && !isnothing(trade)
            apply_trade!(s, ai, o, trade; decommit)
        end
    else
        @debug "replay order: replaying trades" _module = LogSyncOrder
        for trade_resp in new_trades
            if exec
                trade!(
                    s,
                    state.order,
                    ai;
                    resp=trade_resp,
                    date=nothing,
                    price=nothing,
                    actual_amount=nothing,
                    fees=nothing,
                    slippage=false,
                )
            else
                trade = maketrade(s, o, ai; resp=trade_resp)
                @debug "replay order: applying new trade" _module = LogSyncOrder trade.order.id
                apply_trade!(s, ai, o, trade; decommit)
            end
        end
    end
    if isfilled(ai, o)
        clear_order!(s, ai, o)
        event!(ai, AssetEvent, :order_closed_replayed, s; order=o)
    elseif filled_amount(o) > 0.0 && o isa IncreaseOrder
        @ifdebug if ai ∉ s.holdings
            @debug "sync orders: asset not in holdings" _module = LogSyncOrder ai
        end
        push!(s.holdings, ai)
    end
    o
end

@doc """ Performs actions after a trade for any limit order.

$(TYPEDSIGNATURES)

This function checks if the order is filled and removes it from the active orders in the live strategy if it is.

"""
function aftertrade_nocommit!(s, ai, o::AnyLimitOrder, _)
    if isfilled(ai, o)
        delete!(s, ai, o)
    end
end
function aftertrade_nocommit!(s, ai, o::Union{AnyFOKOrder,AnyIOCOrder}, _)
    delete!(s, ai, o)
    isfilled(ai, o) || call!(s, o, NotEnoughCash(_cashfrom(s, ai, o)), ai)
end
aftertrade_nocommit!(_, _, o::AnyMarketOrder, args...) = nothing
@doc """ Applies a trade to a strategy without updating cash.

$(TYPEDSIGNATURES)

This function fills the order with the trade and adds the trade to the asset's history or the trades of the order.
After applying the trade, the function performs actions specified in 'aftertrade_nocommit!' function.
"""
function apply_trade!(s::LiveStrategy, ai, o, trade; decommit=false)
    isnothing(trade) && return nothing
    fill!(s, ai, o, trade)
    push!(ai.history, trade)
    @deassert trade.order == o
    @ifdebug let found = findorder(s, ai; id=o.id, side=orderside(o))
        if found != o
            @error "replay order: duplicate" found o
        end
    end
    push!(trades(o), trade)
    if decommit
        aftertrade!(s, ai, o, trade)
    else
        aftertrade_nocommit!(s, ai, o, trade)
    end
end

@doc """ Checks synchronization of orders in a live strategy.

$(TYPEDSIGNATURES)

This function locks all assets in the universe of the strategy, and checks if the tracked order ids and the local order ids match the order ids from the exchange.
If there are any discrepancies, the function logs an error message. If the ids are all matching, the function logs a message stating the number of orders currently being tracked.

"""
function check_orders_sync(s::LiveStrategy)
    try
        lock.(s.universe)
        eid = exchangeid(s)
        local_ids = Set(o.id for o in values(s))
        exc_ids = Set{String}()
        tracked_ids = Set{String}()
        @sync for ai in s.universe
            @async for o in fetch_open_orders(s, ai)
                push!(exc_ids, resp_order_id(o, eid, String))
            end
            for id in keys(active_orders(ai))
                push!(tracked_ids, id)
            end
        end
        if length(tracked_ids) != length(exc_ids)
            @error "Tracked ids not matching exchange ids" non_exc_ids = Set(
                id for id in tracked_ids if id ∉ exc_ids
            ) non_tracked_ids = Set(id for id in exc_ids if id ∉ tracked_ids)
        end
        if length(local_ids) != length(exc_ids)
            @error "Local ids not matching exchange ids" non_exc_ids = Set(
                id for id in local_ids if id ∉ exc_ids
            ) non_local_ids = Set(id for id in exc_ids if id ∉ local_ids)
        end
        @assert all(id ∈ exc_ids for id in local_ids)
        @assert all(id ∈ exc_ids for id in tracked_ids)
        @info "Currently tracking $(length(tracked_ids)) orders"
    finally
        unlock.(s.universe)
    end
end

@doc """ Synchronizes closed orders for a single asset in a live strategy.

$(TYPEDSIGNATURES)

This function fetches closed orders from the exchange for an asset.
If it's successful, it locks the asset and processes each closed order.
For each closed order, it retrieves the order id and finds or creates a corresponding order in the strategy.
If an order can be found or created, the function checks if the order is filled.
If it is, it asserts that the order has trades, and if it isn't, it replays the order.
Afterwards, the order is deleted from the active orders.

!!! warning "Leverage information not available"
    It is not possible to correctly sync the trade history of an asset because the leverage and margin information of the asset at the time of each trade is not available from the exchange. As a result, the leverage of all trades replayed from closed orders is currently set to 1.0.
!!! Warning "Position side unknown"
    CCXT orders structures don't have position side, hence to properly reconstruct the position history the exchange must either support `fetchPositionHistory` (or maybe `fetchLedger`), but currently these function are not checked/used
    (there is a constrained case that could be generally supported, when syncing the last trades up to the current state and knowing the current position state, the trades position state can be checked for correctness and flipped in case of wrong initial Long/Short guess)
"""
function live_sync_closed_orders!(
    s::LiveStrategy, ai; dowarn=true, create_kwargs=(;), side=BuyOrSell, waitfor=Minute(1), kwargs...
)
    @timeout_start
    if dowarn
        @warn "closed orders syncing doesn't support leverage and position side!"
    end
    eid = exchangeid(ai)
    closed_orders = @lget! _closed_orders_resp_cache(s.attrs, ai) LATEST_RESP_KEY let
        resp = fetch_closed_orders(s, ai; side, kwargs...)
        isnothing(resp) ? [] : [resp...]
    end
    if isnothing(closed_orders)
        @error "sync closed orders: couldn't fetch orders, skipping sync" ai s = nameof(s)
        return nothing
    end
    order_kwargs = withoutkws(:skipcommit, :tag; kwargs=create_kwargs)
    @debug "sync closed orders: iterating" _module = LogSyncOrder ai n_closed = length(
        closed_orders
    )

    default_pos = get_position_side(s, ai)
    i = 1
    limit = attr(s, :sync_history_limit)
    events = get_events(ai)
    ids = Set{String}()
    for resp in closed_orders
        if resp_event_type(resp, eid) != ot.Order
            continue
        end
        if i > limit
            break
        end
        i += 1
        id = resp_order_id(resp, eid, String)
        if !(id isa String) || isempty(id)
            continue
        end
        push!(ids, id)
        date = resp_order_timestamp(resp, eid)
        function func()
            o = (@something findorder(s, ai; resp, id, side) _create_live_order(
                s,
                ai,
                resp;
                t=_ccxtposside(s, resp, eid; def=default_pos),
                price=missing,
                amount=missing,
                synced=false,
                skipcommit=true,
                activate=false,
                tag="replay_closed",
                order_kwargs...,
            ) missing)::Union{Order,Missing}
            if !ismissing(o)
                @deassert resp_order_status(resp, eid, String) ∈
                    ("closed", "open", "canceled") resp_order_status(resp, eid, String)
                @ifdebug trades_count = length(ai.history)
                if isempty(trades(o))
                    if isopen(ai, o)
                        reset!(o, ai)
                    end
                    replay_order!(s, o, ai; resp, exec=false)
                    @deassert length(ai.history) > trades_count
                end
                delete!(s, ai, o)
                @deassert !hasorders(s, ai, o.id)
            end
            pop!(ids, id)
        end
        sendrequest!(ai, date, func; events)
    end
    waitforcond(() -> isempty(ids), @timeout_now())
end

@doc """ Synchronizes closed orders for all assets in a live strategy.

$(TYPEDSIGNATURES)

This function performs an asynchronous operation for each asset in the universe of the strategy to synchronize their closed orders.

"""
function live_sync_closed_orders!(s::LiveStrategy; kwargs...)
    @sync for ai in universe(s)
        @async live_sync_closed_orders!(s, ai; kwargs...)
    end
end

function live_sync_open_orders!(s::LiveStrategy, ai; kwargs...)
    @lock ai _live_sync_open_orders!(s, ai; kwargs...)
end

@doc """ Synchronizes open orders for all assets in a live strategy.

$(TYPEDSIGNATURES)

This function performs an asynchronous operation for each asset in the universe of the strategy to synchronize their open orders.

"""
function live_sync_open_orders!(s::LiveStrategy; kwargs...)
    @sync for ai in universe(s)
        @async live_sync_open_orders!(s, ai; kwargs...)
    end
end
