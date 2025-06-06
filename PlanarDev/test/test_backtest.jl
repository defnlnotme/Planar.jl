using PlanarDev.Stubs
using Test
using .Planar.Engine.Simulations.Random
using PlanarDev.Planar.Engine.Lang: @m_str

openval(s, a) = s.universe[a].ohlcv.open[begin]
closeval(s, a) = s.universe[a].ohlcv.close[end]
test_synth(s) = begin
    @test openval(s, m"sol") == 101.0
    @test closeval(s, m"sol") == 1753.0
    @test openval(s, m"eth") == 99.0
    @test closeval(s, m"eth") == 574.0
    @test openval(s, m"btc") == 97.0
    @test closeval(s, m"btc") == 123.0
end

_ai_trades(s) = s[m"eth"].history
eq1(a, b) = isapprox(a, b; atol=1e-1)
test_nomargin_market(s) = begin
    @test egn.marginmode(s) isa egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:market)
    egn.start!(s)
    @test first(_ai_trades(s)).order isa egn.MarketOrder
    @info "TEST: " s.cash.value
    @test eq1(Cash(:USDT, 9.39228334), s.cash.value)
    @test eq1(Cash(:USDT, 0.0), s.cash_committed)
    @test st.trades_count(s) == 4657
    mmh = st.minmax_holdings(s)
    @test mmh.count == 0
    @test mmh.min[1] == :USDT
    @test mmh.min[2] ≈ Inf
    @test mmh.max[1] == :USDT
    @test mmh.max[2] ≈ 0.0 atol = 1e-4
end

test_nomargin_gtc(s) = begin
    @test marginmode(s) isa egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:gtc)
    egn.start!(s)
    @test first(_ai_trades(s)).order isa egn.GTCOrder
    @info "TEST: " s.cash.value
    @test eq1(Cash(:USDT, 7615.8), s.cash.value)
    @test eq1(Cash(:USDT, 0.0), s.cash_committed)
    @test st.trades_count(s) == 10105
    mmh = st.minmax_holdings(s)
    @test mmh.count == 0
    @test mmh.min[1] == :USDT
    @test mmh.min[2] ≈ Inf atol = 1e3
    @test mmh.max[1] == :USDT
    @test mmh.max[2] ≈ 0 atol = 1e3
end

test_nomargin_ioc(s) = begin
    @test marginmode(s) isa egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:ioc)
    egn.start!(s)
    @test first(_ai_trades(s)).order isa egn.IOCOrder
    @info "TEST: " s.cash.value
    @test Cash(:USDT, 694.909e3) ≈ s.cash atol = 1
    @info "TEST: " s.cash_committed.value
    @test Cash(:USDT, -0.4e-7) ≈ s.cash_committed atol = 1e-6
    @test st.trades_count(s) == 10244
    mmh = st.minmax_holdings(s)
    @test mmh.count == 0
    @test mmh.min[1] == :USDT
    @test mmh.min[2] ≈ Inf atol = 1e-1
    @test mmh.max[1] == :USDT
    @test mmh.max[2] ≈ 0.0 atol = 1e-1
end

test_nomargin_fok(s) = begin
    @test marginmode(s) isa egn.NoMargin
    s.attrs[:overrides] = (; ordertype=:fok)
    # increase cash to trigger order kills
    s.config.initial_cash = 1e6
    s.config.min_size = 1e3
    egn.start!(s)
    @test first(_ai_trades(s)).order isa egn.FOKOrder
    @test Cash(:USDT, 999.547) ≈ s.cash atol = 1e-1
    @test Cash(:USDT, 0.0) ≈ s.cash_committed atol = 1e-7
    @test st.trades_count(s) == 2051
    mmh = st.minmax_holdings(s)
    reset!(s, true)
    @test mmh.count == 1
    @test mmh.min[1] == :BTC
    @test mmh.min[2] ≈ 4.068469375875e6 atol = 1e2
    @test mmh.max[1] == :BTC
    @test mmh.max[2] ≈ 4.068469375875e6 atol = 1e2
end

function margin_overrides(ot=:market)
    (;
        ordertype=ot,
        def_lev=10.0,
        longdiff=1.02,
        buydiff=1.01,
        selldiff=1.012,
        long_k=0.02,
        short_k=0.02,
        per_order_leverage=false,
        verbose=false,
    )
end

test_margin_market(s) = begin
    s[:per_order_leverage] = false
    @test marginmode(s) isa egn.Isolated
    s.attrs[:overrides] = margin_overrides(:market)
    egn.start!(s)
    @test first(_ai_trades(s)).order isa ect.AnyMarketOrder
    @test Cash(:USDT, -0.056) ≈ s.cash atol = 1e-3
    @test Cash(:USDT, 0.0) ≈ s.cash_committed atol = 1e-1
    @test ect.tradescount(s) == st.trades_count(s) == 480
    mmh = st.minmax_holdings(s)
    @test mmh.count == 0
    @test mmh.min[1] == :USDT
    @test mmh.min[2] ≈ Inf atol = 1e-3
    @test mmh.max[1] == :USDT
    @test mmh.max[2] ≈ 0.0 atol = 1e-3
end

test_margin_gtc(s) = begin
    @test marginmode(s) isa egn.Isolated
    s.attrs[:overrides] = margin_overrides(:gtc)
    egn.start!(s)
    @test first(_ai_trades(s)).order isa ect.AnyGTCOrder
    @test Cash(:USDT, -0.105) ≈ s.cash atol = 1e-3
    @test Cash(:USDT, 0.0) ≈ s.cash_committed atol = 1e-1
    @test st.trades_count(s) == 541
    mmh = st.minmax_holdings(s)
    reset!(s, true)
    @test mmh.count == 0
    @test mmh.min[1] == :USDT
    @test mmh.min[2] ≈ Inf atol = 1e-3
    @test mmh.max[1] == :USDT
    @test mmh.max[2] ≈ 0.0 atol = 1e-3
end

test_margin_fok(s) = begin
    @test marginmode(s) isa egn.Isolated
    s.attrs[:overrides] = margin_overrides(:fok)
    # increase cash to trigger order kills
    s.config.initial_cash = 1e6
    s.config.min_size = 1e3
    egn.start!(s)
    @test first(_ai_trades(s)).order isa ect.AnyFOKOrder
    @test Cash(:USDT, -0.036) ≈ s.cash atol = 1e1
    @test Cash(:USDT, 0.0) ≈ s.cash_committed atol = 1e1
    @test st.trades_count(s) == 2352
    mmh = st.minmax_holdings(s)
    reset!(s, true)
    @test mmh.count == 0
    @test mmh.min[1] == :USDT
    @test mmh.min[2] ≈ Inf atol = 1e-3
    @test mmh.max[1] == :USDT
    @test mmh.max[2] ≈ 0.0 atol = 1e-3
end

test_margin_ioc(s) = begin
    @test marginmode(s) isa egn.Isolated
    s.attrs[:overrides] = margin_overrides(:ioc)
    # increase cash to trigger order kills
    s.config.initial_cash = 1e6
    s.config.min_size = 1e3
    egn.start!(s)
    @test first(_ai_trades(s)).order isa ect.AnyIOCOrder
    @test Cash(:USDT, -0.048) ≈ s.cash atol = 1e1
    @test Cash(:USDT, 0.0) ≈ s.cash_committed atol = 1e-1
    @test st.trades_count(s) == 2354
    mmh = st.minmax_holdings(s)
    reset!(s, true)
    @test mmh.count == 0
    @test mmh.min[1] == :USDT
    @test mmh.min[2] ≈ Inf atol = 1e-3
    @test mmh.max[1] == :USDT
    @test mmh.max[2] ≈ 0.0 atol = 1e-3
end

_nomargin_backtest_tests(s) = begin
    @testset test_synth(s)
    @testset test_nomargin_market(s)
    @testset test_nomargin_gtc(s)
    @testset test_nomargin_ioc(s)
    @testset test_nomargin_fok(s)
end

_margin_backtest_tests(s) = begin
    @testset test_margin_market(s)
    @testset test_margin_gtc(s)
    @testset test_margin_ioc(s)
    @testset test_margin_fok(s)
end

test_backtest() = begin
    @eval begin
        using PlanarDev.Planar.Engine: Engine as egn
        using .egn.Instruments: Cash
        Planar.@environment!
        using .Planar.Engine.Strategies: reset!
        if isnothing(Base.find_package("BlackBoxOptim")) && @__MODULE__() == Main
            import Pkg
            Pkg.add("BlackBoxOptim")
        end
    end
    # NOTE: Don't override exchange of these tests, since they rely on
    # specific assets precision/limits
    @testset failfast = FAILFAST "backtest" begin
        s = backtest_strat(:Example)
        @info "TEST: Example strat" exc = nameof(exchange(s))
        invokelatest(_nomargin_backtest_tests, s)

        s = backtest_strat(:ExampleMargin)
        @info "TEST: ExampleMargin strat" exc = nameof(exchange(s))
        invokelatest(_margin_backtest_tests, s)
    end
end
