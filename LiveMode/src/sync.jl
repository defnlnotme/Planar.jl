using .Executors:
    hold!,
    queue!,
    decommit!,
    position!,
    reset!,
    PositionOpen,
    PositionClose,
    PositionTrade,
    isqueued,
    hastrade,
    tradescount,
    _check_committment,
    order_byid,
    tradetuple
using .st: Strategy, SimStrategy, asset_bysym
using PaperMode.SimMode.Executors: _update_from_trade!

function live_sync_universe_cash!(s::LiveStrategy, args...; kwargs...)
    _live_sync_universe_cash!(s, args...; kwargs...)
end

function live_sync_strategy_cash!(
    s::LiveStrategy, args...; waitfor=Second(5), bal=nothing, overwrite=false, kwargs...
)
    if isnothing(bal)
        bal = live_balance(s; kwargs...)
    end
    func = () -> _live_sync_strategy_cash!(s, args...; overwrite, waitfor, bal)
    sendrequest!(s, bal.date, func, waitfor + Second(1))
end

function live_sync_cash!(
    s::MarginStrategy{Live},
    ai,
    pside=get_position_side(s, ai);
    waitfor=Second(5),
    pup=nothing,
    since=nothing,
    force=false,
    synced=true,
    reset=true,
    kwargs...,
)
    if isnothing(pup)
        pup = live_position(s, ai, pside; since, force, synced, waitfor)
    end
    if pup isa PositionTuple
        func =
            () -> _live_sync_cash!(
                s, ai, pside; waitfor, pup, since, force, synced, kwargs...
            )
        sendrequest!(ai, pup.date, func, ms(waitfor + Second(1)))
    elseif isopen(ai, pside)
        @warn "sync: no position structure" ai pside since force synced
        if reset
            @warn "sync: resetting asset" ai pside since force synced
            reset!(ai, pside)
        end
    end
end

function live_sync_cash!(
    s::NoMarginStrategy{Live},
    ai,
    args...;
    waitfor=Second(5),
    bal=nothing,
    since=nothing,
    force=false,
    synced=true,
    kwargs...,
)
    if isnothing(bal)
        bal = live_balance(s, ai; waitfor, since, force, synced)
    end
    if bal isa BalanceSnapshot
        this_f = () -> _live_sync_cash!(s, ai, args...; waitfor, synced, force, kwargs...)
        sendrequest!(ai, bal.date, this_f, ms(waitfor + Second(1)))
    else
        @warn "sync: no balance structure" ai since force synced
    end
end

function _astuple(ev, tr)
    timestamp = Data.todata(tr._buf, ev[1])
    event = if !(timestamp isa DateTime)
        @warn "data: corrupted event trace, expected timestamp" v = timestamp maxlog = 1
        # HACK: try to get the timestamp from the event
        event = timestamp
        timestamp = if hasproperty(event, :timestamp)
            event.timestamp
        else
            DateTime(0)
        end
        event
    else
        Data.todata(tr._buf, ev[2])
    end
    (; timestamp, event)
end
function order_from_event(s, ev)
    o = if hasproperty(ev.event, :order)
        ev.event.order
    elseif hasproperty(ev.event, :data) && hasproperty(ev.event.data, :order)
        ev.event.data.order
    else
        @error "data: corrupted event trace, expected order" ev.event
    end
    ai = st.asset_bysym(s, raw(o.asset))
    o, ai
end
function trade_tuple(trade)
    timestamp = trade.timestamp
    price = trade.price
    amount = trade.amount
    asset = trade.order.asset
    (; timestamp, price, amount, asset)
end

function execute_trade!(s, o, ai, trade)
    _update_from_trade!(s, ai, o, trade; actual_price=trade.price)
    position!(s, ai, trade; check_liq=false)
    isfilled(ai, o) && @assert !hasorders(s, ai, o.id) typeof(o), o isa AnyMarketOrder
    track!(s, :replay_n_trades)
end

@doc "Returns the number of trades replayed."
function replay_position!(s::SimStrategy, ai, o::Order)
    this_pos = position(ai, o)
    n = 0
    for t in trades(o)
        # @assert !(t in trades(ai))
        if t.date >= timestamp(this_pos)
            position!(s, ai, t; check_liq=false)
            n += 1
        else
            @warn "replay: trade date is older than position" ai o.id t.date timestamp(
                this_pos
            )
        end
    end
    return n
end

function prepare_replay!(live_s::LiveStrategy)
    if !attr(live_s, :defaults_set, false)
        st.default!(live_s; skip_sync=true)
    end
    s = st.similar(live_s; mode=Sim())
    reset!(s)
    return s
end

function copy_cash!(dst_ai::A, src_ai::A) where {A<:NoMarginInstance}
    cash!(dst_ai, cash(src_ai))
    committed!(dst_ai, committed(src_ai))
end

function copy_cash!(dst_ai::A, src_ai::A) where {A<:MarginInstance}
    cash!(cash(dst_ai, Long()), cash(src_ai, Long()))
    cash!(committed(dst_ai, Long()), committed(src_ai, Long()))
    cash!(cash(dst_ai, Short()), cash(src_ai, Short()))
    cash!(committed(dst_ai, Short()), committed(src_ai, Short()))
end

init_tracker!(s::SimStrategy) = begin
    s[:replay_n_trades] = 0
    s[:replay_n_orders] = 0
end
track!(s::SimStrategy, what, n=1) = begin
    s[what] += n
end

# TODO: a method to disable `call!` calls in SimMode during trace replay must be implemented
@doc """ Reconstructs strategy state for events trace.

NOTE: Previous ohlcv data must be present from the date of the first event to replay.
"""
function replay_from_trace!(s::LiveStrategy; check=false)
    sim_s = prepare_replay!(s)
    tr = exchange(s)._trace
    events = [_astuple(ev, tr) for ev in eachrow(tr._arr)]
    sort!(events; by=ev -> ev.timestamp)
    replay_loop!(sim_s, events; check)
    for (live_ai, sim_ai) in zip(s.universe, sim_s.universe)
        # copy the trades history from the sim strategy to the live strategy
        this_trades = trades(live_ai)
        empty!(this_trades)
        append!(this_trades, trades(sim_ai))
        copy_cash!(live_ai, sim_ai)
    end
    empty!(s.holdings)
    for o in values(sim_s)
        hold!(s, st.asset_bysym(s, raw(o.asset)), o)
    end
    n_trades_replayed = sim_s.replay_n_trades
    n_trades = tradescount(sim_s)
    if n_trades_replayed != n_trades
        @error "trace replay: tracked trades mismatch" _module = LogTraceReplay n_trades_replayed n_trades
    end
    n_orders_tracked = sim_s.replay_n_orders
    n_closed_orders = length((closedorders(sim_s)...,))
    n_open_orders = length(orders(sim_s))
    n_replayed_orders = length(union((o.id for o in closedorders(sim_s)), values(sim_s)))
    if n_orders_tracked != n_closed_orders + n_open_orders
        n_all_open_orders = length(orders(sim_s, Val(:universe)))
        @error "trace replay: tracked orders mismatch" _module = LogTraceReplay n_orders_tracked n_closed_orders n_open_orders n_all_open_orders n_replayed_orders
    end
end

function check_state(s::SimStrategy; orders_processed, orders_active)
    closed_orders = Set(o.id for o in closedorders(s))
    tracked_orders = union(keys(orders_processed), keys(orders_active))
    open_orders = Set(o.id for o in values(s))
    replayed_orders = union(closed_orders, open_orders)
    if length(closed_orders) != length((closedorders(s)...,))
        error("trace replay: duplicate closed orders")
    end
    for o in values(s, Val(:universe))
        ai = st.asset_bysym(s, raw(o.asset))
        if !(ai in s.holdings)
            error(
                "trace replay: asset with orders not in holdings $ai $(o.id) filled: $(isfilled(ai, o))",
            )
        end
    end
    for id in replayed_orders
        if !(id in tracked_orders)
            @error "trace replay: order not in tracked orders" id
            o = @something get(orders_active, id, nothing) get(
                orders_processed, id, nothing
            ) missing
            if ismissing(o)
                error("trace replay: order not tracked $id")
            end
            ai = st.asset_bysym(s, raw(orders_active[id].asset))
            @error "trace replay: order not in processed orders" id orders_active[id] hasorders(
                s, ai, id
            ) findorder(ai, id) length(closed_orders) length(open_orders) length(
                replayed_orders
            ) length(orders_active) length(orders_processed) length(tracked_orders)
        end
    end
end

function replay_loop!(s::SimStrategy, events; check=false)
    since_idx = findlast(
        ev -> ev.event.tag == :strategy_started && ev.event.group == nameof(s), events
    )
    orders_processed = Dict{String,Order}()
    orders_active = Dict{String,Order}()
    init_tracker!(s)
    for idx in (since_idx + 1):lastindex(events)
        ev = events[idx]
        if ev.event.group != nameof(s)
            continue
        end
        tag = ev.event.tag
        if tag == :order_created
            trace_create_order!(s, ev; orders_active, orders_processed)
        elseif tag == :order_closed
            trace_close_order!(s, ev; replayed=false, orders_active, orders_processed)
        elseif tag in (:trade_created, :trade_created_emulated)
            trace_execute_trade!(s, ev; orders_processed, orders_active)
        elseif tag == :order_closed_replayed
            @debug "trace replay: order_closed_replayed" _module = LogTraceReplay
            trace_close_order!(s, ev; replayed=true, orders_active, orders_processed)
        elseif tag == :order_local_cancel
            @debug "trace replay: order_local_cancel" _module = LogTraceReplay
            o = ev.event.data.order
            cancel!(s, o, st.asset_bysym(s, raw(o.asset)))
            if isempty(trades(o))
                track!(s, :replay_n_orders, -1)
            end
        elseif tag == :strategy_balance_updated
            trace_balance_update!(s, ev)
        elseif tag == :asset_balance_updated
            @debug "trace replay: asset_balance_updated" _module = LogTraceReplay
            trace_asset_balance_update!(s, ev)
        elseif tag in (
            :position_updated,
            :position_stale_closed,
            :position_oppos_closed,
            :position_updated_closed,
        )
            @debug "trace replay: position_updated" _module = LogTraceReplay
            trace_sync_position!(s, tag, ev.event)
        elseif tag in (
            :margin_mode_set_isolated,
            :margin_mode_set_cross,
            Symbol("margin_mode_set_Isolated Margin"),
            Symbol("margin_mode_set_Isolated Margin"),
        )
            @debug "trace replay: margin_mode_set_isolated" _module = LogTraceReplay
            trace_sync_margin!(s, ev.event)
        elseif tag == :leverage_updated
            @debug "trace replay: leverage_updated" _module = LogTraceReplay
            trace_sync_leverage!(s, ev.event)
        elseif tag == :strategy_stopped
            @debug "trace replay: strategy_stopped" _module = LogTraceReplay
            break
        elseif tag in (:order_error,) # skip errors
            @debug "trace replay: order_error" _module = LogTraceReplay
        else
            @error "trace replay: unknown event tag" tag ev.timestamp
        end
        if check
            check_state(s; orders_processed, orders_active)
        end
    end
end

@doc """ Synchronizes a position state from a PositionUpdated event.

$(TYPEDSIGNATURES)
"""
function trace_sync_position!(s::SimStrategy, tag::Symbol, ev::PositionUpdated)
    ai = st.asset_bysym(s, ev.asset)
    side, status = ev.side_status
    ai = st.asset_bysym(s, ev.asset)
    pos = position(ai, side)
    if !status
        reset!(pos)
        return nothing
    end
    pos.status[] = status ? PositionOpen() : PositionClose()
    timestamp!(pos, ev.timestamp)
    liqprice!(pos, ev.liquidation_price)
    entryprice!(pos, ev.entryprice)
    maintenance!(pos, ev.maintenance_margin)
    initial!(pos, ev.initial_margin)
    leverage!(pos, ev.leverage)
    notional!(pos, ev.notional)
end

@doc """ Synchronizes a margin state from a MarginUpdated event.
"""
function trace_sync_margin!(s::SimStrategy, ev::MarginUpdated)
    ai = st.asset_bysym(s, ev.asset)
    pos = position(ai, ev.side)
    if timestamp(pos) > DateTime(0) && !isapprox(ev.from, margin(pos); rtol=1e-4)
        @warn "trace replay: margin update from value mismatch" ev.from margin(pos)
    end
    addmargin!(pos, ev.value)
    if !isempty(ev.mode)
        @assert string(marginmode(pos)) == ev.mode
    end
    timestamp!(pos, ev.timestamp)
end

@doc """ Synchronizes a leverage state from a LeverageUpdated event.

$(TYPEDSIGNATURES)
"""
function trace_sync_leverage!(s::SimStrategy, ev::LeverageUpdated)
    ai = st.asset_bysym(s, ev.asset)
    pos = position(ai, ev.side)
    if timestamp(ai) > DateTime(0) && !isapprox(ev.from, leverage(pos); rtol=1e-4)
        @warn "trace replay: leverage update from value mismatch" timestamp(ai) ev.from leverage(
            pos
        )
    end
    leverage!(pos, ev.value)
    timestamp!(pos, ev.timestamp)
end

@doc """ Synchronizes a position state from a PositionUpdated event.

$(TYPEDSIGNATURES)
"""
function trace_create_order!(s::SimStrategy, ev; orders_active, orders_processed)
    o, ai = order_from_event(s, ev)
    @debug "trace replay: order created" ai o.id _module = LogTraceReplay
    @assert !haskey(orders_processed, o.id)
    if hasorders(s, ai, o.id)
        @error "trace replay: order already exists" o.id o
        return nothing
    end
    if trace_queue_order!(s, ai, o; replay=false)
        if !isfilled(ai, o)
            orders_active[o.id] = o
        else
            orders_processed[o.id] = o
        end
    end
end

function trace_queue_order!(s::SimStrategy, ai, o; replay=true)
    hold!(s, ai, o)
    prev_orders = length(orders(s, ai, o))
    queue!(s, o, ai; skipcommit=true)
    if length(orders(s, ai, o)) != prev_orders + 1 && !isfilled(ai, o)
        if ordertype(o) <: MarketOrderType && o isa ReduceOnlyOrder
            push!(s, ai, o) # market orders queue! does not dispatch for market orders in sim mode
            track!(s, :replay_n_orders)
            true
        else
            @error "trace replay: order not queued" ordertype(o) o.id prev_orders length(
                orders(s, ai, o)
            )
            false
        end
    else
        if replay
            n_replayed = replay_position!(s, ai, o)
            append!(trades(ai), trades(o))
            track!(s, :replay_n_trades, n_replayed)
        end
        track!(s, :replay_n_orders)

        true
    end
end

function trace_replay_order!(s::SimStrategy, ai, o)
    hold!(s, ai, o)
    n_replayed = replay_position!(s, ai, o)
    new_trades = trades(o)[(end - n_replayed + 1):end]
    append!(trades(ai), new_trades)
    track!(s, :replay_n_trades, length(new_trades))
end

@doc """ Synchronizes a position state from a PositionUpdated event.

$(TYPEDSIGNATURES)
"""
function trace_close_order!(
    s::SimStrategy, ev; replayed::Bool, orders_active, orders_processed
)
    o, ai = order_from_event(s, ev)
    @debug "trace replay: order_closed" _module = LogTraceReplay o.id ai replayed
    if replayed
        if haskey(orders_processed, o.id)
            @debug "trace replay: order_closed_replayed event for already closed order" _module =
                LogTraceReplay o.id
            return nothing
            # an order that we don't know about
        elseif !haskey(orders_active, o.id)
            @deassert !hasorders(s, ai, o.id)
            if trace_queue_order!(s, ai, o; replay=false)
                orders_active[o.id] = o
            end
        end
        trace_replay_order!(s, ai, o)
    elseif !isempty(trades(o))
        @debug "trace replay: order_closed_replayed event for order with trades" _module =
            LogTraceReplay ai o.id replayed isfilled(ai, o) typeof(o)
        trace_replay_order!(s, ai, o)
    end
    if isqueued(o, s, ai)
        if isfilled(ai, o)
            trades_amount = _amount_from_trades(trades(o)) |> abs
            if !isequal(ai, trades_amount, o.amount, Val(:amount))
                @error "trace replay: unexpected closed order amount" o.id trades_amount o.amount unfilled(
                    o
                )
            end
            decommit!(s, o, ai)
            delete!(s, ai, o)
        else
            @error "trace replay: order_closed event can't be unfilled" o.id o.amount unfilled(
                o
            ) filled_amount(o) isfilled(ai, o) length(trades(o))
        end
    end
    delete!(orders_active, o.id)
    orders_processed[o.id] = o
end

function trace_cancel_order!(s::SimStrategy, ev; orders_active, orders_processed)
    o = ev.event.data.order
    ai = st.asset_bysym(s, raw(o.asset))
    if isqueued(o, s, ai)
        decommit!(s, o, ai, true)
        delete!(s, ai, o)
        err = ev.event.data.err
        st.call!(s, o, err, ai)
    end
    delete!(orders_active, o.id)
    orders_processed[o.id] = o
end

@doc """ Synchronizes a position state from a PositionUpdated event.

$(TYPEDSIGNATURES)
"""
function trace_execute_trade!(s::SimStrategy, ev; orders_processed, orders_active)
    trade = ev.event.data.trade
    if isnothing(trade)
        @debug "trace replay: no trade in event" _module = LogTraceReplay ev
        return nothing
    end
    ai = st.asset_bysym(s, raw(trade.order.asset))
    @debug "trace replay: trade_created" _module = LogTraceReplay ai trade.order.id
    # average_price = ev.event.data.avgp
    # the version in orders_processed should have all trades in it
    order_proc = get(orders_processed, trade.order.id, nothing)
    if !isnothing(order_proc) # the order was closed, so should have all trades
        if !hastrade(ai, order_proc, trade)
            @error "trace replay: trade expected to be in order" trade.order.id order_proc.id length(
                trades(order_proc)
            ) tradetuple(first(trades(order_proc))) tradetuple(trade)
        end
    else
        o = get(orders_active, trade.order.id, nothing) # check if the order exists
        if !isnothing(o) # the order is still open
            if !hastrade(ai, o, trade) # execute the trade
                execute_trade!(s, o, ai, trade)
            end
        else # the trade somewhat has a timestamp older than the order creation or the order event wasn't registered
            # enqueue the order and re-execute the trade
            reset!(trade.order, ai)
            hold!(s, ai, trade.order)
            queue!(s, trade.order, ai; skipcommit=true)
            execute_trade!(s, trade.order, ai, trade)
        end
    end
    @debug "trace replay: trade executed" len = length(trades(ai))
    if isfilled(ai, trade.order)
        delete!(orders_active, trade.order.id)
        orders_processed[trade.order.id] = trade.order
    end
end

@doc """ Synchronizes a position state from a PositionUpdated event.

$(TYPEDSIGNATURES)
"""
function trace_balance_update!(s::SimStrategy, ev)
    bal = ev.event.data.balance
    @debug "trace replay: strategy balance update" _module = LogTraceReplay bal
    if bal.currency == nameof(s.cash)
        kind = s.live_balance_kind
        avl_cash = @something getproperty(bal, kind) 0.0
        if isfinite(avl_cash)
            cash!(s.cash, avl_cash)
        else
            @warn "strategy cash: non finite" c kind bal maxlog = 1
        end
    else
        @error "trace replay: strategy balance wrong currency" event_cur = bal.currency strategy_cur = nameof(
            s.cash
        )
    end
end

@doc """ Synchronizes a position state from a PositionUpdated event.

$(TYPEDSIGNATURES)
"""
function trace_asset_balance_update!(s::SimStrategy, ev)
    bal = ev.data.balance
    ai = st.asset_bysym(s, bal.currency)
    @debug "trace replay: asset balance update" _module = LogTraceReplay ai
    if bal.currency == bc(ai)
        if isfinite(bal.free)
            cash!(ai, bal.free)
        else
            @warn "asset cash: non finite" ai = raw(ai) bal
        end
    else
        @error "trace replay: asset_balance_updated event missing balance" ev.data
    end
end

@doc """ Returns a DataFrame with all errors from the exchange trace.

$(TYPEDSIGNATURES)
"""
function trace_errors(exc::Exchange, group::Symbol=Symbol())
    tr = exc._trace
    events = [_astuple(ev, tr) for ev in eachrow(tr._arr)]
    errors = []
    tags = []
    dates = DateTime[]
    for ev in events
        if ev.event.group == group && ev.event.tag == :order_error
            push!(errors, ev)
            push!(tags, ev.event.tag)
            push!(dates, ev.timestamp)
        end
    end
    DataFrame([dates, tags, errors], [:timestamp, :tag, :error])
end

trace_errors(s::Strategy) = trace_errors(exchange(s), nameof(s))

function trace_initial_cash!(s::LiveStrategy)
    tr = exchange(s)._trace
    events = [_astuple(ev, tr) for ev in eachrow(tr._arr)]
    since_idx = findlast(
        ev -> ev.event.tag == :strategy_started && ev.event.group == nameof(s), events
    )
    for ev in events[(since_idx + 1):end]
        if ev.event.tag == :strategy_balance_updated
            v = s.config.initial_cash = ev.event.data.balance.free
            return v
        end
    end
end

export trace_initial_cash!
