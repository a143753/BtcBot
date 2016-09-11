# coding: utf-8
require 'logger'
class BitcoinBot
  include BotUtils
  attr_accessor :assertions

  def initialize tapi, papi, rule, log_dir, prefix, status_file, sim_mode = true
    @SIM_MODE = sim_mode
    @STATUS_FILE = status_file
    @tapi = tapi
    @papi = papi

    @as = {
      :vBTC   => 20,  # BTC持ち高. 値はtest用
      :vJPY   => 1000 # JPY持ち高. 値はtest用
    }

    @tradeTime = nil
    @da_last = 0

    @recentHigh = 0
    @R = rule
    @history = []
    @touch_u = false
    @touch_d = false
    @touch_l = false

    @ts = loadTradeStatus @STATUS_FILE, 4
    @log = Logger.new("#{log_dir}/#{prefix}.log", "daily")
  end

  def updateAccount
    if @SIM_MODE == false
      res = @tapi.get_info
      if res == nil or not res[:success] then
        # API errorを10回くりかえした後、 nilが返ってきて落ちたことあり(2015/7/13)
        @log.error format("BitcoinBot.updateAccount API Error.")
        @log.error res.to_s
        return false
      end

      @as[:vBTC] = res[:btc]
      @as[:vJPY] = res[:jpy]
      @as[:vBTC_TTL] = res[:btc_ttl]
      @as[:vJPY_TTL] = res[:jpy_ttl]
    end

    @log.info format("ua: vBTC=%f,vJPY=%f,vBTC_TTL=%f,vJPY_TTL=%f", @as[:vBTC], @as[:vJPY], @as[:vBTC_TTL], @as[:vJPY_TTL])
    return true
  end

  def getMarketInfo
    while true do
      @depth  = @papi.get_depth(:btc)
      break if @depth[:success]
      puts "btc.get_depth failed"
      $stdout.flush
      sleep(1)
    end

    if @depth[:asks][0][0] > @recentHigh then
      @recentHigh = @depth[:asks][0][0]
    end

    @history.push(@depth[:asks][0][0])
    @history.delete_at(0) if @history.size > (@R[:tAverage] / @R[:tSleep])

    @log.info format("mi: asks=[%d,%f],bids=[%d,%f],rH=%.1f,avg=%f",
                     @depth[:asks][0][0],@depth[:asks][0][1],
                     @depth[:bids][0][0],@depth[:bids][0][1],
                     @recentHigh,
                     @history.inject(:+) / @history.size)
  end

  def judgeBuy
    # btcを買う判定
    judge = false
    o = ""
    if @tradeTime and Time.now - @tradeTime < 1 * 60 then # 前回取り引きから1分以内
      #judge = false
    else
      havg, hsigma, hratio = analysis(@history,@R[:tSleep])

      firstBuy1 = (havg + hsigma * 2) # 順張り
      firstBuyL = (havg + hsigma * 1) # 順張り
      firstBuy2 = (havg - hsigma)

      if @depth[:asks][0][0] >= firstBuy1 then
        if (@da_last < firstBuy1) and @touch_u == true then
          judge = true
          o = "j"
        end
        @touch_u = false
      elsif @depth[:asks][0][0] < firstBuyL then
        @touch_u = true
      elsif @depth[:asks][0][0] < firstBuy2 then
        if @da_last > firstBuy2 then
          judge = true
          o = "g"
        end
      else
        ;
      end

      @log.info format("jb: fB1=%f,fB2=%f,mB=%.1f,ha=%.1f,hs=%f,hr=%f,judge=%s,o=%s",
                   firstBuy1,firstBuy2,0,havg,hsigma,hratio,judge,o)
    end
    @da_last = @depth[:asks][0][0]
    return judge
  end

  def actionBuy
    # 売買するbtcは0.0001 btc単位
    # price(JPY/BTC)は1円単位
    price = @depth[:asks][0][0]

    # 買う量。持ち分に:ratioKPをかけた分
    vjpy = max( @as[:vJPY] - ( @as[:vJPY_TTL] + price * @as[:vBTC_TTL] ) * @R[:ratioKP], 0 )
    volJpy = ceil_unit(vjpy * @R[:ratioJPY] / price, @R[:uVol])

    # 売りに出ている量が買いたい量より小さい場合は全部買う。
    if volJpy > @depth[:asks][0][1]
      vol = floor_unit(@depth[:asks][0][1], @R[:uVol])
    else
      vol = volJpy
    end

    if @R[:name] == :bitflyer then
      price = ceil_unit( price * vol, 1.0 ) / vol
    end

    @log.info format("ab: vjpy=%f,volJpy=%f,vol=%f,price=%f",vjpy,volJpy,vol,price)

    raise unless is_bigdecimal( [ vol, price ] )
    
    if vol > 0 and vjpy >= vol * price then
      @log.info format(" buy  %f btc at %f", vol, price)
      @tradeTime = Time.now
      if @SIM_MODE then
        @as[:vBTC]    += vol
        @as[:vJPY]    -= vol * price
      else
        ret = @tapi.action_buy(:btc, price, vol)
        if ret == false then
          raise "exception in actionBuy"
        end
      end

      if @ts["buy"] and @ts["buy"].keys.include? price then
        @ts["buy"][price] += vol
      else
        @ts["buy"] = { price => vol }
      end
      @recentHigh = @depth[:asks][0][0]
      saveTradeStatus @ts, @STATUS_FILE unless vol == 0
    end

    raise if @ts["buy"] != nil and !is_bigdecimal @ts["buy"]
  end

  def judgeCloseBuy
    @log.info format("jcb: %s", @ts["buy"].to_s) if @ts["buy"] != nil
    return @ts["buy"] != nil
  end

  def closeBuy
    # 売買するbtcは0.0001 btc単位
    # price(JPY/BTC)は1円単位
    havg, hsigma, hratio = analysis(@history,@R[:tSleep])

    price = ceil_unit(@ts["buy"].keys.sort[0] * (1.01+2*@R[:fee]), @R[:uPrice])

    sum = 0 # まだ売りorderを出していないpositionの合計
    @ts["buy"].keys.each do |k|
      sum += @ts["buy"][k]
    end

    if @as[:vBTC] >= @ts["buy"][@ts["buy"].keys.sort[0]] then
      if @ts["buy"][@ts["buy"].keys.sort[0]] < @R[:uVol] then
        vol = 0
      else
        vol   = @ts["buy"][@ts["buy"].keys.sort[0]]
      end
    else
      # まだaccountに反映されていないので待ち
      # ここで回数を数え、一定回数を越えたらキャンセルする TODO
      return
    end

    # bitFlyerの四捨五入対応
    if @R[:name] == :bitflyer then
      pdash = ceil_unit( ceil_unit( price * vol, 1.0 ) / vol, 1.0 )
      @log.info format(" (bf.sell) orig (%f,%f) mod (%f,%f)", price,vol, pdash, vol )
      price = BigDecimal.new( pdash, 10 )
    end

    raise if price < @ts["buy"].keys.sort[0]

    raise unless is_bigdecimal( [ vol, price ] )

    @log.info format(" sell  %f btc at %f", vol, price)
    if @SIM_MODE then
      @as[:vBTC]    -= vol
      @as[:vJPY]    += vol * price
    else
      ret = @tapi.action_sell(:btc, price, vol)
      if ret == false then
        # order not succeed
        raise "exception in closeBuy"
      end
      sleep(1)
    end

    @ts["buy"].delete @ts["buy"].keys.sort[0]
    if @ts["buy"] == {} then
      @ts["buy"] = nil
    end
    saveTradeStatus @ts, @STATUS_FILE

    @recentHigh = @depth[:asks][0][0]
    
    raise if @ts["buy"] != nil and !is_bigdecimal @ts["buy"]

  end

  def judgeSell
    # btcを買う判定
    judge = false
    o = ""
    if @tradeTime and Time.now - @tradeTime < 1 * 60 then # 前回取り引きから1分以内
      #judge = false
    else
      havg, hsigma, hratio = analysis(@history,@R[:tSleep])

      firstSell1 = (havg - 2 * hsigma) # 順張り
      firstSellL = (havg - hsigma) 
      firstSell2 = (havg + hsigma)     # 逆張り

      if @depth[:bids][0][0] > firstSell2 then # ボリンジャーバンドの上を越えたら
        if @da_last < firstSell2 then
          judge = true
          o = "g"
        end
      elsif @depth[:bids][0][0] > firstSellL then
        @touch_l = true
      elsif @depth[:bids][0][0] < firstSell1 then
        if (@da_last > firstSell1) and @touch_l == true then
          judge = true
          o = "j"
        end
        @touch_l = false
      else
        ;
      end

      @log.info format("js: fS1=%f,fS2=%f,mB=%.1f,ha=%.1f,hs=%f,hr=%f,judge=%s,o=%s",
                   firstSell1,firstSell2,0,havg,hsigma,hratio,judge,o)
    end
    @da_last = @depth[:bids][0][0]
    return judge
  end

  def actionSell
    # 売買するbtcは0.0001 btc単位
    # price(JPY/BTC)は1円単位
    price = @depth[:bids][0][0]

    # 買う量。持ち分に:ratioKPをかけた分
    #    vjpy = max( @as[:vJPY] - ( @as[:vJPY_TTL] + price * @as[:vBTC_TTL] ) * @R[:ratioKP], 0 )
    volJpy = ceil_unit( @as[:vBTC] * @R[:ratioKP] / price, @R[:uVol])

    # 売りに出ている量が買いたい量より小さい場合は全部買う。
    if volJpy > @depth[:bids][0][1]
      vol = floor_unit(@depth[:bids][0][1], @R[:uVol])
    else
      vol = volJpy
    end

    if @R[:name] == :bitflyer then
      price = ceil_unit( price * vol, 1.0 ) / vol
    end

    raise unless is_bigdecimal( [ vol, price ] )
    
    @log.info format("as: volJpy=%f,vol=%f,price=%f",volJpy,vol,price)

    if vol > 0 and vol <= @as[:vBTC] then
      @log.info format(" sell  %f btc at %f", vol, price)
      @tradeTime = Time.now
      if @SIM_MODE then
        @as[:vBTC]    += vol
        @as[:vJPY]    -= vol * price
      else
        ret = @tapi.action_sell(:btc, price, vol)
        if ret == false then
          raise "exception in actionSell"
        end
      end

      if @ts["sell"] and @ts["sell"].keys.include? price then
        @ts["sell"][price] += vol
      else
        @ts["sell"] = { price => vol }
      end
      @recentHigh = @depth[:bids][0][0]
      saveTradeStatus @ts, @STATUS_FILE unless vol == 0
    end

    raise if @ts["sell"] != nil and !is_bigdecimal @ts["sell"]
  end

  def judgeCloseSell
    @log.info format("jcs: %s", @ts["sell"].to_s) if @ts["sell"] != nil
    return @ts["sell"] != nil
  end

  def closeSell
    # 売買するbtcは0.0001 btc単位
    # price(JPY/BTC)は1円単位
    havg, hsigma, hratio = analysis(@history,@R[:tSleep])

    price = ceil_unit(@ts["sell"].keys.sort[0] * (0.99-2*@R[:fee]), @R[:uPrice])

    sum = 0 # まだ売りorderを出していないpositionの合計
    @ts["sell"].keys.each do |k|
      sum += @ts["sell"][k]
    end

    if @as[:vJPY] >= @ts["sell"][@ts["sell"].keys.sort[0]] * price then
      if @ts["sell"][@ts["sell"].keys.sort[0]] < @R[:uVol] then
        vol = 0
      else
        vol   = @ts["sell"][@ts["sell"].keys.sort[0]]
      end
    else
      # まだaccountに反映されていないので待ち
      # ここで回数を数え、一定回数を越えたらキャンセルする TODO
      return
    end

    if @R[:name] == :bitflyer then
      pdash = floor_unit( floor_unit( price * vol, 1.0 ) / vol, 1.0 )
      @log.info format(" (bf.buy) orig (%f,%f) mod (%f,%f)", price,vol, pdash, vol )
      price = BigDecimal.new( pdash, 10 )
    end

    raise if price > @ts["sell"].keys.sort[0]

    raise unless is_bigdecimal( [ vol, price ] )

    @log.info format(" buy  %f btc at %f", vol, price)
    if @SIM_MODE then
      @as[:vBTC]    -= vol
      @as[:vJPY]    += vol * price
    else
      ret = @tapi.action_buy(:btc, price, vol)
      if ret == false then
        # order not succeed
        raise "exception in closeBuy"
      end
      sleep(1)
    end

    @ts["sell"].delete @ts["sell"].keys.sort[0]
    if @ts["sell"] == {} then
      @ts["sell"] = nil
    end
    saveTradeStatus @ts, @STATUS_FILE

    @recentHigh = @depth[:bids][0][0]
    
    raise if @ts["sell"] != nil and !is_bigdecimal @ts["sell"]

  end

  def run
    if updateAccount then
      getMarketInfo

      # これまでは買った次のturnで売ろうとしていたが
      # そうすると別のBotが売りを入れてしまって反対orderを入れられないことがあった
      # そのため、当該turnで売りオーダーを入れることにした。

      # 買いからStart
      if judgeBuy then
        actionBuy
      end
      if judgeCloseBuy then
        closeBuy
      end

      # 売りからStart
      if judgeSell then
        actionSell
      end
      if judgeCloseSell then
        closeSell
      end

    end
    $stdout.flush
  end
end
