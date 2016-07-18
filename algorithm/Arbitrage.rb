# coding: utf-8
require 'rubygems'
require 'yaml'
require 'bigdecimal'
require 'utils/BotUtils.rb'

class Arbitrage
  include BotUtils

  # mkt_x = { :name => str, :papi => public_api, :tapi => trade_api }
  def initialize mkt_a, mkt_b, mkt_c, mkt_d, log_dir
    @mkt = [ mkt_a, mkt_b, mkt_c, mkt_d ]
    @log = File.open(Time.now.strftime("#{log_dir}/arb_%Y%m%d%H%M%S") + ".log", "w")
  end

  def updateAccount
    bal = { :jpy => 0, :jpy_inuse => 0, :btc => 0, :btc_inuse => 0 }
    @as = {}
    @mkt.each do |m|
      res = m[:tapi].get_info
      if res[:success] == false then
        @log.printf("api error: %s.get_info\n",m[:name])
        return false
      end
      @log.printf("%s: JPY %f, %f(In Use), BTC %f, %f(In Use)\n",m[:name],
                  res[:jpy],
                  res[:jpy_ttl] - res[:jpy],
                  res[:btc],
                  res[:btc_ttl] - res[:btc] )
      @as[ m[:name] ] = { :vBTC => res[:btc], :vJPY => res[:jpy] }

      bal[:jpy] += res[:jpy]
      bal[:btc] += res[:btc]
      
      if res[:open_orders] then
        res2 = m[:tapi].get_active_orders(:btc)
        if res2[:success] == true then
          res2[:orders].each do |o|
            if o[:type] == "sell" then
              bal[:jpy_inuse] += o[:price] * o[:amount]
            elsif o[:type] == "buy" then
              bal[:btc_inuse] += o[:amount]
            end
          end
        else
          @log.printf("api error: %s.get_active_orders\n",m[:name])
          return false
        end
      end
    end
    price = @mkt[0][:papi].get_last_price(:btc)

    if price[:success] then
      @log.printf("%s ", Time.now.strftime("%Y-%m-%d %H:%M:%S"))
      @log.printf("JPY %f/%f/%f\t", bal[:jpy], bal[:jpy_inuse], bal[:jpy] + bal[:jpy_inuse])
      @log.printf("BTC %f/%f/%f/%f  ", bal[:btc], bal[:btc_inuse], bal[:btc] + bal[:btc_inuse],
                  (bal[:btc] + bal[:btc_inuse])*price[:price] )
      @log.printf("//%.2f%%, %.2f%%\n", 100 * bal[:jpy] /(bal[:jpy] + bal[:btc]*price[:price]),
                  100 * (bal[:jpy] + bal[:jpy_inuse]) / ( bal[:jpy] + bal[:jpy_inuse] + (bal[:btc] + bal[:btc_inuse]) * price[:price]) )
    end
    return true
  end

  def checkAndAction
    bids = []
    asks = []

    @mkt.each do |m|
      d = m[:papi].get_depth(:btc)

      if d[:success] == false or d[:asks] == nil or d[:asks][0] == nil or d[:bids] == nil or d[:bids][0] == nil then
        @log.printf("api error %s::get_depth\n", m[:name] )
        return
      end

      # 売り板のオーダー
      uVol = m[:rule][:uVol]
      asks.push [ d[:asks][0][0],
                  min(d[:asks][0][1],floor_unit(@as[m[:name]][:vJPY]*m[:rule][:ratioJPY]/d[:asks][0][0], uVol))
                ]

      # 買い板のオーダー
      bids.push [ d[:bids][0][0],
                  min(d[:bids][0][1],floor_unit(@as[m[:name]][:vBTC]*m[:rule][:ratioJPY],uVol))]
      
    end

    # 一番Gainが大きい組み合わせをさがす。
    max_gain = 0.01 # 0.01以上のgainがないと取引しない。
    max_vol  = 0
    max_pair = [-1,-1]
    ( 0 .. asks.size - 1 ).each do |i|
      ( 0 .. bids.size - 1 ).each do |j|

        uVol = max( @mkt[i][:rule][:uVol], @mkt[j][:rule][:uVol] )
        
        vol = floor_unit( min( asks[i][1], bids[j][1] ), uVol )

        if @mkt[i][:name] == "bitFlyer" then
          # 不確定なのでworst caseで考える。
          # 自分が売るときは高い方
          a = ceil_unit( asks[i][0] * vol, 1.0 )
        else
          a = asks[i][0] * vol
        end
        if @mkt[j][:name] == "bitFlyer" then
          # 不確定なのでworst caseで考える。
          # 自分が買うときは高い方
          b = floor_unit( bids[j][0] * vol, 1.0 )
        else
          b = bids[j][0] * vol
        end

        afee = @mkt[i][:rule][:fee] * a
        bfee = @mkt[j][:rule][:fee] * b

        gain = b - a - afee - bfee

        if gain > max_gain and vol > 0 and (bids[j][0] / asks[i][0] < 1.02) then
          @log.printf("  afee = %f, bfee = %f\n", afee, bfee )
          max_gain = gain
          max_pair = [i, j]
          max_vol  = vol
        end
      end
    end

    if max_pair != [ -1, -1 ] then
      @log.printf("%s: %s sells p=%s %s buys p=%s amount=%s, gain=\\%f\n",
                  Time.now.strftime("%Y-%m-%d %H:%M:%S"),
                  @mkt[max_pair[0]][:name],
                  asks[max_pair[0]][0],
                  @mkt[max_pair[1]][:name],
                  bids[max_pair[1]][0],
                  max_vol,
                  max_gain )

      ret = @mkt[max_pair[1]][:tapi].action_sell( :btc, bids[max_pair[1]][0], max_vol )
      if ret then
        ret = @mkt[max_pair[0]][:tapi].action_buy(  :btc, asks[max_pair[0]][0], max_vol )
        if not ret then
          @log.printf "# action_buy to %s failed\n", @mkt[max_pair[0]][:name]
        end
      else
        @log.printf "# action_sell to %s failed\n", @mkt[max_pair[1]][:name]
      end
    end

  end

  def run
    if updateAccount
      checkAndAction
    end
    if @log.closed? then
      $stdout.printf("Arbitrage @log closed\n")
    end
    $stdout.flush
    @log.flush
  end

end
