@doc """ Logs a warning if a position is unsynced

$(TYPEDSIGNATURES)

This macro logs a warning if a position is not in sync between local and remote states.
The warning includes the provided message, position details, and the instance and strategy names.

"""
macro warn_unsynced(what, loc, rem, msg="unsynced")
    ex = quote
        (
            if wasopen
                @debug "Position $($msg) ($($what)) local: $($loc), remote: $($rem) $this_timestamp ($(raw(ai))@$(nameof(s)))" _module =
                    LogPosSync
            end
        )
    end
    esc(ex)
end

function _sync_oppos!(s, ai, pside, update, forced_side; waitfor)
    eid = exchangeid(ai)
    @debug "sync pos: handling double position" _module = LogPosSync ai pside
    pos = position(ai, pside)
    wasopen = isopen(pos)
    oppside = opposite(pside)
    oppos = position(ai, oppside)

    oppos_pup = live_position(s, ai, oppside; since=forced_side ? update.date : nothing)
    if !isnothing(oppos_pup)
        live_pos = oppos_pup.resp
        oppos_amount = resp_position_contracts(live_pos, eid)
        if !oppos_pup.closed[] && !oppos_pup.read[] && oppos_amount > 0.0
            if wasopen
                @warn "sync pos: double position open in oneway mode." oppside cash(ai, oppside) ai nameof(
                    s
                ) f = @caller
            end
            if forced_side
                call!(s, ai, oppside, now(), PositionClose(); amount=oppos_amount, waitfor)
                oppos = position(ai, oppside)
                if isopen(oppos)
                    @warn "sync pos: refusing sync since opposite side is still open" ai pside amount oppside oppos_amount
                    return pos
                end
            elseif oppos_pup.date > update.date
                @debug "sync pos: resetting this side since oppside is newer" _module =
                    LogPosSync ai pside oppside amount oppos_amount
                update.closed[] = true
                update.read[] = true
                reset!(ai, pside)
                timestamp!(pos, update.date)
                event!(ai, PositionUpdated(:position_stale_closed, s, pos))
                let func = () -> live_sync_position!(s, ai, oppside, oppos_pup)
                    sendrequest!(ai, oppos_pup.date, func)
                end
                return pos
            end
        end
        if isopen(oppos)
            @debug "sync pos: resetting oppside pos" _module = LogPosSync ai oppside
            reset!(ai, oppside)
        end
        oppos_pup.closed[] = true
        oppos_pup.read[] = true
        timestamp!(oppos, oppos_pup.date)
    else
        @debug "sync pos: resetting opposite position" _module = LogPosSync ai oppside
        reset!(ai, oppside)
        timestamp!(oppos, update.date)
    end
    event!(ai, PositionUpdated(:position_oppos_closed, s, oppos))
end

@doc """ Synchronizes the live position.

$(TYPEDSIGNATURES)

This function synchronizes the live position with the actual position in the market.
It does this by checking various parameters such as the amount, entry price, leverage, notional, and margins.
If there are discrepancies, it adjusts the live position accordingly.
For instance, if the amount in the live position does not match the actual amount, it updates the live position's amount.
It also checks for conditions like whether the position is open or closed, and if the position is hedged or not.
If the position is closed, it resets the position. If the position is open, it updates the timestamp of the position.
`forced_side` auto closes the opposite position side when `true.

!!! warn
    This functions should be called with the `update` lock held.

"""
function _live_sync_position!(
    s::LiveStrategy,
    ai::MarginInstance,
    p::Option{ByPos},
    update::PositionTuple;
    amount=resp_position_contracts(update.resp, exchangeid(ai)),
    ep_in=resp_position_entryprice(update.resp, exchangeid(ai)),
    commits=true,
    skipchecks=false,
    overwrite=false,
    forced_side=false, # NOTE: not checked to be deadlock free
    waitfor=Second(5),
)
    @debug "sync pos: checking queue" ai isownable(s.lock) isownable(ai.lock)
    let queue = asset_queue(ai)
        if queue[] > 1
            @debug "sync pos: events queue is congested" _module = LogPosSync ai queue[]
            return nothing
        end
    end
    eid = exchangeid(ai)
    resp = update.resp
    pside = posside_fromccxt(resp, eid, p)
    pos = position(ai, pside)
    wasopen = isopen(pos) # by macro warn_unsynced
    @debug "sync pos: vars" _module = LogPosSync cash = cash(pos) sym = raw(ai) wasopen pside skipchecks overwrite

    # check hedged mode
    if !resp_position_hedged(resp, eid) == ishedged(pos)
        @warn "sync pos: hedged mode mismatch" ai loc = ishedged(pos)
        @assert marginmode!(
            exchange(ai),
            _ccxtmarginmode(ai),
            raw(ai),
            hedged=ishedged(pos),
            lev=leverage(pos),
        ) "failed to set hedged mode on exchange ($(ai))"
    end

    # hedged mode checks
    if !skipchecks
        if !ishedged(pos) && isopen(opposite(ai, pside)) && !update.closed[]
            _sync_oppos!(s, ai, pside, update, forced_side; waitfor)
        end
    end

    # read checks
    update.read[] && begin
        @debug "sync pos: update already read" _module = LogPosSync ai pside overwrite update.closed[] resp_position_contracts(
            resp, eid
        )
        if !overwrite
            return pos
        end
    end

    # closed checks
    if update.closed[]
        if !isdust(ai, _ccxtposprice(ai, resp), pside) && isfinite(cash(pos))
            @warn "sync pos: cash expected to be (close to) zero, found" ai cash = cash(
                ai, pside
            ) cash(ai, pside).precision resp_position_contracts(resp, eid)
        end
        update.read[] = true
        reset!(ai, pside) # if not full reset at least cash/committed
        timestamp!(pos, update.date)
        event!(ai, PositionUpdated(:position_updated_closed, s, pos))
        @debug "sync pos: closed flag set, reset" _module = LogPosSync ai pside pos
        return pos
    end

    # timestamp checks
    this_timestamp = update.date
    if this_timestamp <= timestamp(pos) && !overwrite
        @debug "sync pos: position timestamp not newer" _module = LogPosSync timestamp(pos) this_timestamp overwrite f = @caller
        return pos
    end

    # Margin/hedged mode are immutable so just check for mismatch
    let mm = resp_position_margin_mode(resp, eid)
        if !pyisnone(mm) && pyne(Bool, mm, _ccxtmarginmode(pos))
            @warn "sync pos: position margin mode mismatch (attempt switch..)" ai loc = marginmode(
                pos
            ) rem = mm
            if !marginmode!(
                exchange(ai),
                _ccxtmarginmode(ai),
                raw(ai);
                hedged=ishedged(pos),
                lev=leverage(pos),
            )
                @warn "sync pos: mismatching margin mode will cause corrupted state" ai
            end
        end
    end

    # resp cash, (always positive for longs, or always negative for shorts)
    let rv = islong(pos) ? positive(amount) : negative(amount)
        @debug "sync pos: amount" _module = LogPosSync ai resp_amount = amount rv posside(
            pos
        )
        if !isequal(ai, cash(pos), rv, Val(:amount))
            @warn_unsynced "amount" posside(pos) abs(cash(pos)) amount
        end
        # TODO: should also be checked for finiteness? probably not?
        cash!(pos, rv)
    end
    # If the resp amount is "dust" the position should be considered closed, and to be reset
    pos_price = _ccxtposprice(ai, resp)
    if isdust(ai, pos_price, pside)
        update.read[] = true
        reset!(ai, pside)
        @debug "sync pos: amount is dust, reset" _module = LogPosSync ai pside isopen(ai, p) cash(
            ai, pside
        ) resp
        return pos
    end
    @debug "sync pos: syncing" _module = LogPosSync ai timestamp(pos) pside
    pos.status[] = PositionOpen()
    let lap = ai.lastpos
        if isnothing(lap[]) || timestamp(ai, opposite(pside)) <= this_timestamp
            lap[] = pos
        end
    end
    function dowarn(what, val)
        @debug what resp _module = LogPosSync
        @warn "sync pos: $(ai) unable to sync $what from $(nameof(exchange(ai))), got $val"
    end
    # price is always positive
    ep = pytofloat(ep_in)
    ep = if ep > zero(DFT)
        if !isapprox(entryprice(pos), ep; rtol=1e-3)
            @warn_unsynced "entryprice" entryprice(pos) ep
        end
        entryprice!(pos, ep)
        ep
    else
        entryprice!(pos, pos_price)
        dowarn("entry price", ep)
        pos_price
    end
    if commits
        let comm = committed(s, ai, pside)
            @debug "sync pos: local committment" _module = LogPosSync comm ai pside
            if !isapprox(committed(pos).value, comm)
                commit!(pos, comm)
            end
        end
    end

    lev = resp_position_leverage(resp, eid)
    prev_lev = let v = leverage(pos)
        v < one(v) ? one(DFT) : v
    end
    if lev > zero(DFT)
        if !isapprox(prev_lev, lev; atol=1e-2)
            @warn_unsynced "leverage" leverage(pos) lev
        end
        leverage!(pos, lev)
    else
        dowarn("leverage", lev)
        lev = prev_lev
    end
    ntl = let v = resp_position_notional(resp, eid)
        if v > zero(DFT)
            ntl = notional(pos)
            if !isapprox(ntl, v; rtol=0.05)
                @warn_unsynced "notional" ntl v "error too high"
            end
            notional!(pos, v)
            v
        else
            price = pos_price
            v = price * cash(pos)
            notional!(pos, v)
            notional(pos)
        end
    end
    @assert ntl > 0.0 "sync pos: notional can't be zero ($ai)"

    tier!(pos, ntl)
    lqp = resp_position_liqprice(resp, eid)
    # NOTE: Also don't warn about liquidation price because same as notional
    liqprice_set =
        lqp > zero(DFT) && begin
            if !isapprox(liqprice(pos), lqp; rtol=0.05)
                @warn_unsynced "liqprice" liqprice(pos) lqp "error too high"
            end
            liqprice!(pos, lqp)
            true
        end

    mrg = resp_position_initial_margin(resp, eid)
    coll = resp_position_collateral(resp, eid)
    adt = max(zero(DFT), coll - (mrg + 2(mrg * maxfees(ai))))
    mrg_set =
        mrg > zero(DFT) && begin
            if !isapprox(mrg, margin(pos); rtol=1e-2)
                @warn_unsynced "initial margin" margin(pos) mrg
            end
            initial!(pos, mrg)
            if !isapprox(adt, additional(pos); rtol=1e-2)
                @warn_unsynced "additional margin" additional(pos) adt
            end
            additional!(pos, adt)
            true
        end
    mm = resp_position_maintenance_margin(resp, eid)
    mm_set =
        mm > zero(DFT) && begin
            if !isapprox(mm, maintenance(pos); rtol=0.05)
                @warn_unsynced "maintenance margin" maintenance(pos) mm
            end
            maintenance!(pos, mm)
            true
        end
    # Since we don't know if the exchange supports all position fields
    # try to emulate the ones not supported based on what is available
    _margin!() = begin
        margin!(pos; ntl, lev)
        additional!(pos, max(zero(DFT), coll - margin(pos)))
    end

    if !liqprice_set
        liqprice!(
            pos,
            liqprice(
                pside, ep, lev, _ccxtmmr(resp, pos, eid); additional=adt, notional=ntl
            ),
        )
    end
    if !mrg_set
        _margin!()
    end
    if !mm_set
        update_maintenance!(pos; mmr=_ccxtmmr(resp, pos, eid))
    end
    function higherwarn(whata, whatb, a, b)
        "sync pos: ($(raw(ai))) $whata ($(a)) can't be higher than $whatb ($(b))"
    end
    @assert maintenance(pos) <= collateral(pos) higherwarn(
        "maintenance", "collateral", maintenance(pos), collateral(pos)
    )

    @assert liqprice(pos) > 0.0 "liqprice can't be negative ($(liqprice(pos)))"
    @assert entryprice(pos) > 0.0 "entryprice can't be negative ($(entryprice(pos)))"
    @assert notional(pos) > 0.0 "notional can't be negative ($(notional(pos)))"

    @assert liqprice(pos) <= entryprice(pos) || isshort(pside) higherwarn(
        "liquidation price", "entry price", liqprice(pos), entryprice(pos)
    )
    @assert committed(pos) <= abs(cash(pos)) higherwarn(
        "committment", "cash", abs(committed(pos)), abs(cash(pos))
    )
    @assert leverage(pos) <= maxleverage(pos) higherwarn(
        "leverage", "max leverage", leverage(pos), maxleverage(pos)
    )
    if pos.min_size <= notional(pos)
        @assert abs(cash(pos)) >= ai.limits.amount.min higherwarn(
            "min size", "notional", pos.min_size, notional(pos)
        )
    end
    timestamp!(pos, this_timestamp)
    @debug "sync pos: synced" _module = LogPosSync ai this_timestamp resp_position_contracts(
        update.resp, eid
    ) posside(ai) cash(ai) isopen(ai, Long()) isopen(ai, Short()) f = @caller
    update.read[] = true
    event!(ai, PositionUpdated(:position_updated, s, pos))
    return pos
end

function live_sync_position!(s::LiveStrategy, ai::MarginInstance, pos, update; kwargs...)
    @debug "sync pos: syncing update" _module = LogPosSync ai = raw(ai) isownable(ai.lock) isownable(
        s.lock
    ) isownable(update.notify.lock)
    # NOTE: Orders matters to avoid deadlocks
    @inlock ai @lock update.notify begin
        _live_sync_position!(s, ai, pos, update; kwargs...)
        if isopen(ai) || hasorders(s, ai)
            push!(s.holdings, ai)
        else
            delete!(s.holdings, ai)
        end
    end
end

function live_sync_position!(
    s::LiveStrategy,
    ai::MarginInstance,
    pos::ByPos;
    force=false,
    since=nothing,
    waitfor=Second(5),
    kwargs...,
)
    update = live_position(s, ai, pos; force, since, waitfor)
    if isnothing(update)
        @warn "live sync pos: no update found" ai pos force since
    else
        live_sync_position!(s, ai, pos, update; kwargs...)
    end
end

function live_sync_position!(s::LiveStrategy, ai::HedgedInstance; kwargs...)
    @sync for pos in (Long, Short)
        @async live_sync_position!(s, ai, $pos; kwargs...)
    end
end

function live_sync_position!(s::LiveStrategy, ai::MarginInstance; kwargs...)
    live_sync_position!(s, ai, get_position_side(s, ai); kwargs...)
end

@doc """ Synchronizes the cash position in a live trading strategy.

$(TYPEDSIGNATURES)

This function synchronizes the cash position of a given asset in a live trading strategy.
It checks the current position status and updates it accordingly.
If the position is closed, it resets the position.
If the position is open, it synchronizes the position with the market.
The function locks the asset instance during the update to prevent race conditions.

"""
function _live_sync_cash!(
    s::MarginStrategy{Live},
    ai,
    bp::ByPos=get_position_side(s, ai);
    since=nothing,
    waitfor=Second(5),
    force=false,
    synced=true,
    overwrite=true,
    pside=posside(bp),
    pup=nothing,
    kwargs...,
)
    @timeout_start
    pup = @something pup live_position(s, ai, pside; since, force, synced, waitfor) missing
    if pup isa PositionTuple
        @assert isnothing(since) || (timestamp(ai, pside) < since && pup.date >= since)
        live_sync_position!(s, ai, pside, pup; overwrite, kwargs...)
    else
        @debug "sync cash: resetting position cash (not found)" _module = LogUniSync ai = raw(
            ai
        ) pside
        @inlock ai reset!(ai, bp)
    end
    position(ai, bp)
end

@doc """ Synchronizes the cash position for all assets in a live trading strategy.

$(TYPEDSIGNATURES)

This function synchronizes the cash position for all assets in a live trading strategy.
It iterates over each asset in the universe and synchronizes its cash position.
The function uses a helper function `dosync` to perform the synchronization for each asset.
The synchronization process is performed concurrently for efficiency.

"""
function _live_sync_universe_cash!(
    s::MarginStrategy{Live}; overwrite=false, force=false, waitfor=Second(5), kwargs...
)
    if force # wait for position watcher
        waitwatcherupdate(() -> watch_positions!(s))
        waitwatcherupdate(() -> watch_balance!(s))
    end
    long, short, _ = get_positions(s)
    default_date = now()
    function dosync(ai, pside, dict)
        pup = get(dict, raw(ai), nothing)
        @debug "sync universe cash:" _module = LogUniSync ai pside isnothing(pup) overwrite force
        live_sync_cash!(s, ai, pside; pup, overwrite, waitfor, force, kwargs...)
    end
    @sync for ai in s.universe
        @async begin
            @sync begin
                @async dosync(ai, Long(), long)
                @async dosync(ai, Short(), short)
            end
            set_active_position!(ai; default_date)
        end
    end
    @debug "sync universe cash: synced" _module = LogUniSync
end
