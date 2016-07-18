# -*- coding: utf-8 -*-
# programで保持する値
class MonaBot
  include BotUtils
  attr_accessor :assertions

  def initialize tapi, papi, sim_mode = true
    @SIM_MODE = sim_mode
    @STATUS_FILE = "../dat/mona_status.yml" # TODO 競合解決
    @tapi = tapi
    @papi = papi

    @as = {
      :vMona    => 20,  # mona持ち高. 値はtest用
      :vJPY     => 1000 # JPY持ち高. 値はtest用
    }

    @tradeTime = nil
    @da_last = 0

    @recentHigh = 0
    @R = {
      :fee           => 0.0,
      :ratioJPY	   => 0.01,
      :uVol          => BigDecimal.new("1.0"),
      :uPrice        => BigDecimal.new("0.1"),
      :tSleep        => 15,   # seconds
      :tAverage      => 6*60*60 # seconds
    }
    @history = []
    @touch_u = false
    @touch_d = false
    @ts = loadTradeStatus @STATUS_FILE, 1
    @log = File.open(Time.now.strftime("mona_%Y%m%d%H%M%S") + ".log", 'w')
  end

  def updateAccount
    if @SIM_MODE == false
      res = @tapi.get_info
      if res['success'] != 1 then
        @log.printf("API Error.\n")
        return false
      end

      @as[:vMona] = res['return']['funds']['mona']
      @as[:vJPY]  = res['return']['funds']['jpy']
    end
    @log.printf("dt: %s\n", Time.now.strftime("%Y-%m-%d %H:%M:%S"))
    @log.printf("as: vMona=%f,vJPY=%f,avg=%f\n", @as[:vMona], @as[:vJPY], calcAverage(@ts))
    return true
  end

  def getMarketInfo
    while true do
      @depth  = @papi.get_depth(:mona)
      break if @depth
      puts "mona.get_depth failed"
      p @depth
      sleep(1)
    end

    if @depth['asks'][0][0] > @recentHigh then
      @recentHigh = @depth['asks'][0][0]
    end

    @history.push(@depth['asks'][0][0])
    @history.delete_at(0) if @history.size > (@R[:tAverage] / @R[:tSleep])

    # 重心
    cgs = calcCg(@depth['asks'], @depth['bids'])

    @log.printf("mi: asks=[%.1f,%d],bids=[%.1f,%d],rH=%.1f,my_avg=%f,avg=%f,acg=%f,bcg=%f,cg=%f\n",
                @depth['asks'][0][0],@depth['asks'][0][1],
                @depth['bids'][0][0],@depth['bids'][0][1],
                @recentHigh,
                calcAverage(@ts),
                @history.inject(:+) / @history.size,
                cgs[0],cgs[1],cgs[2])
  end

  def judgeSell
    @log.printf("js: %s\n", @ts.to_s) if @ts != nil
    return @ts != nil
  end

  def judgeBuy
    # monaを買う判定
    judge = false
    o = ""
    if @tradeTime and Time.now - @tradeTime < 15 * 60 then # 前回取り引きから15分以内
      judge = false
    else
      avg   = calcAverage(@ts)
      havg, hsigma, hratio = analysis(@history,@R[:tSleep])

      firstBuy1 = (havg + hsigma) # 順張り
      firstBuyL = (havg + hsigma * 2) # 順張り limit
      firstBuy2 = (havg - hsigma)

      # 逆張りで買う場合、1度平均に戻るまで次は買わない
      if @depth['asks'][0][0] >= havg then
        @touch_d = false
      end
      if @depth['asks'][0][0] <= havg then
        @touch_u = false
      end

      if    (@da_last < firstBuy1) and (@depth['asks'][0][0] > firstBuy1) and (@depth['asks'][0][0]<firstBuyL) then
        # 順張り
        if @touch_u then
          #                    judge = true
          judge = false # 順張りは不調なので無効
          o = "j"
        else
          judge = false
        end
        @touch_u = true
      elsif (@da_last > firstBuy2) and (@depth['asks'][0][0] < firstBuy2) then
        if not @touch_d  then
          judge = true
          o = "g"
        else
          judge = false
        end
        @touch_d = true
      end

      @log.printf("jb: fB1=%f,fB2=%f,mB=%.1f,ha=%.1f,hs=%f,hr=%f,judge=%s\n",
                   firstBuy1,firstBuy2,0,havg,hsigma,hratio,judge)
    end
    @da_last = @depth['asks'][0][0]
    return judge
  end

  def actionBuy
    # 売買するmonaは1mona単位
    # price(JPY/MONA)は0.1円単位

    price = @depth['asks'][0][0]

    volJpy = ceil_unit(@as[:vJPY] * @R[:ratioJPY] / price, @R[:uVol])

    if volJpy > @depth['asks'][0][1]
      vol = @depth['asks'][0][1]
    else
      vol = Integer(volJpy)
    end

    if @as[:vJPY] >= vol * price then
      @log.printf(" buy  %f mona at %f\n", vol, price)
      @tradeTime = Time.now
      if @SIM_MODE then
        @as[:vMona]    += vol
        @as[:vJPY]     -= vol * price
      else
        ret = @tapi.action_buy(:mona, price, vol)
        if ret == -1 then
          raise "exception in actionBuy"
        end
      end

      if @ts and @ts.keys.include? price then
        @ts[price] += vol
      else
        @ts = { price => vol }
      end
      @recentHigh = @depth['asks'][0][0]
      saveTradeStatus @ts, @STATUS_FILE unless vol == 0
    end
  end

  def actionSell
    # 売買するmonaは1mona単位
    # price(JPY/MONA)は0.1円単位
    havg, hsigma, hratio = analysis(@history,@R[:tSleep])

    if @history.size < 100 then
      price = ceil_unit(@ts.keys.sort[0] + @R[:uPrice], @R[:uPrice])
    else
      if hsigma / @ts.keys.sort[0] > 0.01 then
        price = ceil_unit(@ts.keys.sort[0] * 1.01, @R[:uPrice])
      else
        price = ceil_unit(@ts.keys.sort[0] + 0.5 * hsigma, @R[:uPrice])
      end
    end

    sum = 0
    @ts.keys.each do |k|
      sum += @ts[k]
    end
    if @as[:vMona] > @ts[@ts.keys.sort[0]] then
      vol   = @ts[@ts.keys.sort[0]]
      if ceil_unit((@as[:vMona] - sum) * 0.01, @R[:uVol]) <= @as[:vMona] - sum then
        vol += ceil_unit((@as[:vMona] - sum) * 0.01, @R[:uVol])
      end
    else
      # まだaccountに反映されていないので待ち
      return
    end

    @log.printf(" sell  %f mona at %f\n", vol, price)
    if @SIM_MODE then
      @as[:vMona]    -= vol
      @as[:vJPY]     += vol * price
    else
      ret = @tapi.action_sell(:mona, price, vol)
      if ret == -1 then
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

    @recentHigh = @depth['asks'][0][0]
  end

  def run
    $stdout.puts("MonaBot")
    $stdout.flush
    while true do
      @log.printf("w")
      $lock.lock
      @log.printf("g\n")
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
      $lock.unlock

      @log.flush
      sleep(@R[:tSleep])
    end
  end
end

######################################################################
######################################################################

