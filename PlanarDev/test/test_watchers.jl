using Test

macro deser!(v)
    v = esc(v)
    quote
        buf = IOBuffer($v)
        try
            v = deserialize(buf)
            take!(buf)
            v
        finally
            close(buf)
        end
    end
end

function _test_save(k, w)
    z = Data.load_data(k; serialized=true)
    prevsz = size(z, 1)
    d1 = prevsz[1] > 0 ? z[end, 1] : NaN
    wa.flush!(w)
    z = Data.load_data(k; serialized=true)
    newsz = size(z, 1)
    d2 = newsz[1] > 0 ? z[end, 1] : NaN
    @info "TEST: " newsz prevsz
    @test d1 == d2 || d1 === d2 || newsz > prevsz
end

function _test_watchers_1()
    w = wi.cg_ticker_watcher("bitcoin", "ethereum", byid=true)
    @test w.name == "cg_ticker-15280856976725193512"
    @test w.buffer isa DataStructures.CircularBuffer
    @test w.interval.flush == Minute(6)
    @test w.interval.flush == Minute(6)
    wa.fetch!(w)
    if wi.cg.STATUS[] == 200
        @test length(w.buffer) > 0
        @test now() - (last(w.buffer).time) < Minute(12)
        k = "cg_ticker_btc_eth"
        delete!(Data.zi[].store, k)
        _test_save(k, w)
    else
        @warn "TEST: coingecko error" wi.cg.STATUS[]
    end
end

function _test_watchers_2()
    w = wi.cg_derivatives_watcher("binance_futures")
    @test w.name == "cg_derivatives-16819285695551769070"
    wa.fetch!(w)
    if wi.cg.STATUS[] == 200
        @test length(w.buffer) > 0
        @test last(w).value isa Dict{wi.Derivative,wi.CgSymDerivative}
        k = "cg_binance_futures_derivatives"
        delete!(Data.zi[].store, k)
        _test_save(k, w)
    end
end

test_watchers() = @testset failfast = FAILFAST "watchers" begin
    @eval begin
        using .Planar.Engine.LiveMode.Watchers
        using .Planar.Data
        using .Planar.Data.DataStructures
        using .Planar.Data.Serialization
        using .Planar.Engine.TimeTicks
        wa = Watchers
        isdefined(@__MODULE__, :wi) || (wi = wa.WatchersImpls)
    end
    @info "TEST: watchers 1"
    _test_watchers_1()
    @info "TEST: watchers 2"
    _test_watchers_2()
end
