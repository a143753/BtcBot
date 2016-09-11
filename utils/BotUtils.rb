# -*- coding: utf-8 -*-
######################################################################
######################################################################
module BotUtils

  def loadTradeStatus(status_file,pre)

    unless File.exist? status_file
      f = File.open status_file, "w"
      f.puts nil.to_yaml
      f.close
    end
    
    f = File.open status_file
    trade_status = YAML::load f
    f.close

    if trade_status == nil then
      trade_status = { "buy" => nil, "sell" => nil }
    else
      ["buy", "sell"].each do |act|
        if trade_status[act] != nil then
          trade_status[act].keys.each do |k|
            trade_status[act][k] = BigDecimal.new(trade_status[act][k],pre)
          end
        end
      end
    end
    return trade_status
  end

  def saveTradeStatus(trade_status, status_file)
    f = File.open(status_file, 'w')
    YAML.dump(trade_status, f)
    f.close
  end

  def min(a, b)
    if a < b then
      return a
    else
      return b
    end
  end

  def max(a, b)
    if a > b then
      return a
    else
      return b
    end
  end

  def calcCg(asks, bids)
    len = min(bids.size, min(asks.size, 10))

    asum = 0
    anum = 0
    bsum = 0
    bnum = 0
    for i in 0 .. len - 1 do
      asum += asks[i][0] * asks[i][1]
      anum += asks[i][1]
      bsum += bids[i][0] * bids[i][1]
      bnum += bids[i][1]
    end
    return asum / anum, bsum / bnum, (asum + bsum) / (anum + bnum)
  end

  def analysis(history, tsleep)
    avg = history.inject(:+) / history.size

    tmp = 0
    history.each do |h|
      tmp += (h-avg)**2
    end
    if history.size < 100 then
      sigma = avg
    else
      sigma = Math::sqrt(tmp/history.size)
    end

    ratio = history[history.size-1] / history[0] - 1.0

    return avg, sigma, ratio
  end

  def ceil_unit(value, unit)
    return (value / unit).ceil * unit
  end

  def floor_unit(value, unit)
    return (value / unit).floor * unit
  end

  def is_bigdecimal data

    flag = true
    if data.is_a? Array then
      data.each do |e|
        flag &= e.instance_of? BigDecimal
      end
      return flag
    elsif data.is_a? Hash then
      data.keys.each do |k|
        flag &= data[k].instance_of? BigDecimal
      end
      return flag
    else
      return false
    end
    
  end

  # bitFlyerで売買金額を計算する関数(buy)
  def bfBuyAmount( price, vol )
    raise unless is_bigdecimal( [ vol, price ] )
    ttl = price * vol
    # 買う場合はuPriceで切り上げられる
    trn = ceil_unit( ttl, @R[:uPrice] )
    # 切り上げ誤差
    dif = ttl - trn
    # 実際の買い値。ただし、整数になるわけではない。
    act = trn / vol
    # 結局、元のpriceのままorderを出して、売り上げがtrnだと考えればよい
    return trn
  end

  # bitFlyerで売買金額を計算する関数(sell)
  def bfSellAmount( price, vol )
    raise unless is_bigdecimal( [ vol, price ] )
    ttl = price * vol
    # 売る場合はuPriceで切り下げられる
    trn = floor_unit( ttl, @R[:uPrice] )
    # 切り上げ誤差
    dif = trn - ttl
    # 実際の買い値。ただし、整数になるわけではない。
    act = trn / vol
    # 結局、元のpriceのままorderを出して、売り上げがtrnだと考えればよい
    return trn
  end

  # bitFlyerでclose sellの価格を決定する関数
  def bfPriceBuyClose price, vol
    buy_amount = bfBuyAmount price, vol

    psell = price * 1.01 # 1%の利益を載せる
    sell_amount = bfSellAmount psell, vol
    gain = sell_amount - buy_amount

    if gain <= 0 then # もしgainが正でなければ1円の利益を載せる
      psell = ceil_unit( (buy_amount + 1) / vol, @R[:uPrice] )
      sell_amount = bfSellAmount psell, vol
      gain = sell_amount - buy_amount
    end

    raise if gain < 0
    printf("gain=%f\n",gain)
    return psell
  end

  # bitFlyerでclose buyの価格を決定する関数
  def bfPriceSellClose price, vol
    sell_amount = bfSellAmount price, vol

    pbuy = price * 0.99 # 1%の利益を載せる
    buy_amount = bfBuyAmount pbuy, vol
    gain = sell_amount - buy_amount

    if gain <= 0 then # もしgainが正でなければ1円の利益を載せる
      pbuy = floor_unit( (sell_amount - 1) / vol, @R[:uPrice] )
      buy_amount = bfBuyAmount pbuy, vol
      gain = sell_amount - buy_amount
    end

    raise if gain < 0
    printf("gain=%f\n",gain)
    return pbuy
  end

end

