# coding: utf-8
class BtcUsdBot
  include BotUtils
  attr_accessor :assertions

  def initialize tapi, papi, rule, status_file, sim_mode = true
    @SIM_MODE = sim_mode
    @STATUS_FILE = status_file
    @tapi = tapi
    @papi = papi

    @as = {
      :vBTC   => 20,  # BTC持ち高. 値はtest用
      :vUSD   => 1000 # USD持ち高. 値はtest用
    }

    @tradeTime = nil
    @da_last = 0

    @recentHigh = 0
    @R = rule
    @history = []
    @touch_u = false
    @touch_d = false

    @ts = loadTradeStatus @STATUS_FILE, 4
    @log = File.open(Time.now.strftime("btc_%Y%m%d%H%M%S") + ".log", "w")
  end

  def updateAccount
    if @SIM_MODE == false
      res = @tapi.get_info
      if res == nil or not res[:success] then
        # API errorを10回くりかえした後、 nilが返ってきて落ちたことあり(2015/7/13)
        @log.puts res.to_s
        @log.printf("API Error.\n")
        return false
      end

      if res[:open_orders] == true then
        cancelOrder
      end

      @as[:vBTC] = res[:btc]
      @as[:vUSD] = res[:usd]
    end
    @log.printf("dt: %s\n", Time.now.strftime("%Y-%m-%d %H:%M:%S"))
    @log.printf("as: vBTC=%f,vUSD=%f,avg=%f\n", @as[:vBTC], @as[:vUSD], calcAverage(@ts))
    return true
  end

  def cancelOrder
    while true do
      sleep(1)
      ret = @tapi.get_active_orders(:btc)
      break if ret[:success]
    end

    ret[:orders].each do |order|
      if order[:type] == "buy" then

        # 買い注文を発行して5分以上activeだったらcancelする
        if (Time.now - order[:timestamp]).to_i > 5*60 then
          @tapi.cancel_order(order[:id])
          @log.printf("cancel %s\n", order.to_s )
          @log.printf("@ts = %s\n", @ts.to_s )

          if @ts then
            @ts.keys.each do |k|
              if k == order[:price] then
                if @ts[k] == order[:amount] then
                  @ts = nil
                else
                  @ts[k]  -= order[:amount]
                end
              end
            end
          else
            # 持ち高がask orderより大きい場合、askが成立していなくてもbidを出してしまう
            # その場合、@tsがnilであることがありうる。
            @log.printf(" bid order already issued\n")
            #raise "order and @ts mismatch error"
          end
        end
      end
    end
    raise if @ts != nil and !is_bigdecimal @ts
  end

  def getMarketInfo
    while true do
      @depth  = @papi.get_depth(:btc)
      break if @depth[:success]
      puts "btc.get_depth failed"
      p @depth
      sleep(1)
    end

    if @depth[:asks][0][0] > @recentHigh then
      @recentHigh = @depth[:asks][0][0]
    end

    @history.push(@depth[:asks][0][0])
    @history.delete_at(0) if @history.size > (@R[:tAverage] / @R[:tSleep])

    @log.printf("mi: asks=[%d,%f],bids=[%d,%f],rH=%.1f,my_avg=%f,avg=%f\n",
                @depth[:asks][0][0],@depth[:asks][0][1],
                @depth[:bids][0][0],@depth[:bids][0][1],
                @recentHigh,
                calcAverage(@ts),
                @history.inject(:+) / @history.size)
  end

  def judgeSell
    @log.printf("js: %s\n", @ts.to_s) if @ts != nil
    return @ts != nil
  end

  def judgeBuy
    # btcを買う判定
    judge = false
    o = ""
    if @tradeTime and (Time.now - @tradeTime).to_i < 1 * 60 then # 前回取り引きから1分以内
      #judge = false
    else
      avg   = calcAverage(@ts)
      havg, hsigma, hratio = analysis(@history,@R[:tSleep])

      firstBuy1 = (havg + hsigma * 2) # 順張り
      firstBuyL = (havg + hsigma * 1) # 順張り
      firstBuy2 = (havg - hsigma)

      # 逆張りで買う場合、1度平均に戻るまで次は買わない
      if @depth[:asks][0][0] >= havg then
        @touch_d = false
      end
      if @depth[:asks][0][0] <= firstBuyL then
        if @touch_u then
          judge = true
          o = "j"
        end
        @touch_u = false
      end

      if    (@da_last < firstBuy1) and (@depth[:asks][0][0] > firstBuy1) then
        # 順張り
        if @touch_u then
          # judge = true
          # 順張りは不調なので無効
          # o = "j"
        end
        @touch_u = true
      elsif (@da_last > firstBuy2) and (@depth[:asks][0][0] < firstBuy2) then
        if not @touch_d  then
          judge = true
          o = "g"
        end
        @touch_d = true
      end

      @log.printf("jb: fB1=%f,fB2=%f,mB=%.1f,ha=%.1f,hs=%f,hr=%f,judge=%s,o=%s\n",
                   firstBuy1,firstBuy2,0,havg,hsigma,hratio,judge,o)
    end
    @da_last = @depth[:asks][0][0]
    return judge
  end

  def actionBuy
    # 売買するbtcは0.0001 btc単位
    # price(USD/BTC)は1円単位
    price = @depth[:asks][0][0]

    volUsd = ceil_unit(@as[:vUSD] * @R[:ratioUSD] / price, @R[:uVol])
    if volUsd > @depth[:asks][0][1]
      vol = floor_unit(@depth[:asks][0][1], @R[:uVol])
    else
      vol = volUsd
    end

    raise unless is_bigdecimal( [ vol, price ] )
    
    if vol > 0 and @as[:vUSD] >= vol * price then
      @log.printf(" buy  %f btc at %f\n", vol, price)
      @tradeTime = Time.now
      if @SIM_MODE then
        @as[:vBTC]    += vol
        @as[:vUSD]    -= vol * price
      else
        ret = @tapi.action_buy(:btc, price, vol)
        if ret == false then
          raise "exception in actionBuy"
        end
      end

      if @ts and @ts.keys.include? price then
        @ts[price] += vol
      else
        @ts = { price => vol }
      end
      @recentHigh = @depth[:asks][0][0]
      saveTradeStatus @ts, @STATUS_FILE unless vol == 0
    end

    raise if @ts != nil and !is_bigdecimal @ts
  end

  def actionSell
    # 売買するbtcは0.0001 btc単位
    # price(USD/BTC)は1円単位
    havg, hsigma, hratio = analysis(@history,@R[:tSleep])

    ratio = @R[:fee]
    if @history.size < 100 then
        ratio = 0.005
    else
      if hsigma / @ts.keys.sort[0] > 0.01 then
        ratio = 0.01
      else
        ratio = 0.5 * hsigma / @ts.keys.sort[0]
      end
    end

    if ratio > @R[:fee] * 2 then
      price = ceil_unit(@ts.keys.sort[0] * (1.0 + ratio), @R[:uPrice])
    else
      price = ceil_unit(@ts.keys.sort[0] * (1.0 + 2 * @R[:fee] + 0.003 ), @R[:uPrice])
    end

    sum = 0
    @ts.keys.each do |k|
      sum += @ts[k]
    end
    if @as[:vBTC] >= @ts[@ts.keys.sort[0]] then
      vol   = @ts[@ts.keys.sort[0]]
      if ceil_unit((@as[:vBTC] - sum) * 0.01, @R[:uVol]) <= @as[:vBTC] - sum then
        vol += ceil_unit((@as[:vBTC] - sum) * 0.01, @R[:uVol])
      end
    else
      # まだaccountに反映されていないので待ち
      # ここで回数を数え、一定回数を越えたらキャンセルする TODO
      return
    end

    raise unless is_bigdecimal( [ vol, price ] )

    @log.printf(" sell  %f btc at %f\n", vol, price)
    if @SIM_MODE then
      @as[:vBTC]    -= vol
      @as[:vUSD]    += vol * price
    else
      ret = @tapi.action_sell(:btc, price, vol)
      if ret == false then
        # order not succeed
        raise "exception in actionSell"
      end
      sleep(1)
    end

    @ts.delete @ts.keys.sort[0]
    if @ts == {} then
      @ts = nil
    end
    saveTradeStatus @ts, @STATUS_FILE

    @recentHigh = @depth[:asks][0][0]
    
    raise if @ts != nil and !is_bigdecimal @ts

  end

  def run
    if updateAccount then
      sleep(1)

      getMarketInfo
      sleep(1)

      if judgeSell then
        actionSell
      elsif judgeBuy then
        actionBuy
      end
    end 
    $stdout.flush
    @log.flush
  end
end
