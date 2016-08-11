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

    @ts = loadTradeStatus @STATUS_FILE, 4
    #    @log = File.open(Time.now.strftime("#{log_dir}/#{prefix}_%Y%m%d%H%M%S") + ".log", "w")
    @log = Logger.new("#{log_dir}/#{prefix}.log", "daily")
  end

  def updateAccount
    if @SIM_MODE == false
      res = @tapi.get_info
      if res == nil or not res[:success] then
        # API errorを10回くりかえした後、 nilが返ってきて落ちたことあり(2015/7/13)
        @log.error format("BitcoinBot.updateAccount API Error.")
        @log.error res.to_s
        p res
        return false
      end

      # if res[:open_orders] == true then
      #   cancelOrder
      # end

      @as[:vBTC] = res[:btc]
      @as[:vJPY] = res[:jpy]
      @as[:vBTC_TTL] = res[:btc_ttl]
      @as[:vJPY_TTL] = res[:jpy_ttl]
    end

    @log.info format("as: vBTC=%f,vJPY=%f,vBTC_TTL=%f,vJPY_TTL=%f,avg=%f", @as[:vBTC], @as[:vJPY], @as[:vBTC_TTL], @as[:vJPY_TTL], calcAverage(@ts))
    return true
  end

  def cancelOrder
    sleep(1)
    ret = @tapi.get_active_orders(:btc)

    ret[:orders].each do |order|
      if order[:type] == "buy" then

        # 買い注文を発行して5分以上activeだったらcancelする
        if Time.now.to_i - order[:timestamp] > 5*60 then
          @tapi.cancel_order(order[:id])
          @log.info format("cancel %s", order.to_s )
          @log.info format("@ts = %s", @ts.to_s )

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
            @log.warn format(" bid order already issued\n")
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

    @log.info format("mi: asks=[%d,%f],bids=[%d,%f],rH=%.1f,my_avg=%f,avg=%f",
                     @depth[:asks][0][0],@depth[:asks][0][1],
                     @depth[:bids][0][0],@depth[:bids][0][1],
                     @recentHigh,
                     calcAverage(@ts),
                     @history.inject(:+) / @history.size)
  end

  def judgeSell
    @log.info format("js: %s", @ts.to_s) if @ts != nil
    return @ts != nil
  end

  def judgeBuy
    # btcを買う判定
    judge = false
    o = ""
    if @tradeTime and Time.now - @tradeTime < 1 * 60 then # 前回取り引きから1分以内
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

    vjpy = max( @as[:vJPY] - ( @as[:vJPY_TTL] + price * @as[:vBTC_TTL] ) * @R[:ratioKP], 0 )

    volJpy = ceil_unit(vjpy * @R[:ratioJPY] / price, @R[:uVol])
    if volJpy > @depth[:asks][0][1]
      vol = floor_unit(@depth[:asks][0][1], @R[:uVol])
    else
      vol = volJpy
    end

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
    # price(JPY/BTC)は1円単位
    havg, hsigma, hratio = analysis(@history,@R[:tSleep])

    if @history.size < 100 then
      price = ceil_unit(@ts.keys.sort[0] * 1.005, @R[:uPrice])
    else
      if hsigma / @ts.keys.sort[0] > 0.01 then
        price = ceil_unit(@ts.keys.sort[0] * 1.01, @R[:uPrice])
      else
        price = ceil_unit(@ts.keys.sort[0] + 0.5 * hsigma, @R[:uPrice])
      end
    end

    sum = 0 # まだ売りorderを出していないpositionの合計
    @ts.keys.each do |k|
      sum += @ts[k]
    end

    if @as[:vBTC] >= @ts[@ts.keys.sort[0]] then
      vol   = @ts[@ts.keys.sort[0]]

      # BTC持ち高の1%単位で、portofolioを調整する
      # unit = ceil_unit((@as[:vBTC] - sum) * 0.01, @R[:uVol])
      # BTCの持ち高比率
      # r = 1.0 - @as[:vJPY] / ( (@as[:vBTC]-sum) * price + @as[:vJPY] )
      # if    r >= @R[:ratioBTC] * 1.05 then  # BTC比率が目標より大きいときは多く売る
      #   vol += unit if unit <= @as[:vBTC] - sum
      # elsif r <= @R[:ratioBTC] * 0.95 then  # BTC比率が目標より小さいときは少なく売る
      #   vol -= unit if vol > unit
      # end
      # @log.info format(" vol=%f, r=%f, unit=%f\n",vol, r, unit)

    else
      # まだaccountに反映されていないので待ち
      # ここで回数を数え、一定回数を越えたらキャンセルする TODO
      return
    end

    raise unless is_bigdecimal( [ vol, price ] )

    @log.info format(" sell  %f btc at %f", vol, price)
    if @SIM_MODE then
      @as[:vBTC]    -= vol
      @as[:vJPY]    += vol * price
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
      getMarketInfo

      # これまでは買った次のturnで売ろうとしていたが
      # そうすると別のBotが売りを入れてしまって反対orderを入れられないことがあった
      # そのため、当該turnで売りオーダーを入れることにした。
      if judgeBuy then
        actionBuy
      end
      if judgeSell then
        actionSell
      end
    end
    $stdout.flush
  end
end
