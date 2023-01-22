using Test

function _test_orders_1()
    @eval setexchange!(:kucoinfutures)
    @eval using Instruments
    @eval using JuBot.Engine: Orders, Instances
    @eval using JuBot.Exchanges
    @eval using .Orders;
    @eval using .Instances
    @eval using JuBot.Python
    s = "BTC/USDT:USDT"
    asset = Derivative(s)
    inst = instance(asset)
    o = Order(asset, exc.id; amount=123.1234567891012, price=0.12333333333333333)
    @eval using JuBot.Engine.Checks
    sanitized = sanitize_order(inst, o)
    @assert !isnothing(sanitized)
    amt_prec = @py Int(exc.markets[s]["precision"]["amount"])
    prc_prec = @py Int(exc.markets[s]["precision"]["price"])
    @assert sanitized.price != o.price
    @assert sanitized.amount != o.amount
    ccxt_amt_prec = pyconvert(Float64, @py float(exc.py.decimalToPrecision(sanitized.amount; precision=amt_prec)))
    ccxt_prc_prec = pyconvert(Float64, @py float(exc.py.decimalToPrecision(sanitized.price; precision=prc_prec)))
    # NOTE: this comparison might fail cause floats
    @assert Bool(@py sanitized.price == ccxt_prc_prec) "$(sanitized.price) != $(ccxt_prc_prec)"
    @assert Bool(@py sanitized.amount == ccxt_amt_prec) "$(sanitized.amount) != $(ccxt_amt_prec)"
    true
end

test_orders() = @testset "orders" begin
    @test begin _test_orders_1() end
end
