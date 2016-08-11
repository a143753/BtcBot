# coding: utf-8
require 'rubygems'
require 'json'
require 'net/http'
require 'net/https'
require 'openssl'
require 'uri'
require 'yaml'
require 'bigdecimal'

module Etwings
  class TradeApi
    attr_reader :result
    attr_reader :response

    def initialize public_key, secret_key
      @public_key = public_key
      @secret_key = secret_key
      @response = nil
      @result = nil
      @nonce = Time.new.to_i
    end

    def post(method, params)
      @nonce += 1
      hmac = OpenSSL::HMAC.new(@secret_key, OpenSSL::Digest::SHA512.new)
      params['nonce'] = @nonce.to_s
      params['method'] = method
      param = params.map { |k,v| "#{k}=#{v}" }.join("&")
      digest = hmac.update(param)

      http = Net::HTTP.new('api.zaif.jp', 443)
      http.use_ssl = true
      #            http.set_debug_output(STDERR)
      headers = {
        'Content-Type' => 'application/x-www-form-urlencoded',
        'Key' => @public_key,
        'Sign' => digest.to_s }
      path = '/tapi'

      begin
        response = http.post(path, URI.escape(param), headers)
      rescue => exc
        printf "exception in Etwings::post\n"
        p exc
        @result = nil
        return @result
      end

      if response.code.to_i == 200
        begin
          @result = JSON.parse(response.body)
        rescue => exc
          printf "exception in Etwings::post\n"
          p exc
          @result = nil
          return @result
        end
      else
        printf("etwings::post response error %d\n",response.code.to_i)
        p path
        p URI.escape(param)
        p headers
        @result = nil
      end
      @response = response
      @result
    end

    def action_buy( curr, price, amount )
      if curr == :mona then
        # ask mona売り bid mona買い
        params = {
          "currency_pair" => "mona_jpy",
          "action"        => "bid",
          "price"         => price,
          "amount"        => Integer(amount) }
      #                assert_equal(amount, Integer(amount))
      else
        params = {
          "currency_pair" => "btc_jpy",
          "action"        => "bid",
          "price"         => Integer(price),
          "amount"        => amount }
        #                assert_equal(price, Integer(price))
      end
      ret = post("trade", params )
      if !ret.is_a?(Hash) or ret["success"] != 1 then
        p ret
        p params
        return false
      else
        return true
      end
    end

    def action_sell( curr, price, amount )
      if curr == :mona then
        # ask mona売り bid mona買い
        params = {
          "currency_pair" => "mona_jpy",
          "action"        => "ask",
          "price"         => price,
          "amount"        => Integer(amount) }
      else
        params = {
          "currency_pair" => "btc_jpy",
          "action"        => "ask",
          "price"         => Integer(price),
          "amount"        => amount }
      end

      ret = post("trade", params )

      if !ret.is_a?(Hash) or ret["success"] != 1 then
        p ret
        p params
        return false
      elsif ret["success"] == 1 then
        return true
      end
    end

    # 未決済のorderを取得する
    # { :success => bool,
    #   :orders  => [ { :id        => Integer
    #                   :type      => "buy" or "sell"
    #                   :price     => BigDecimal
    #                   :amount    => BigDecimal
    #                   :timestamp => unix time } ] }
    def get_active_orders( curr )
      if curr == :mona then
        params = { "currency_pair" => "mona_jpy" }
      else 
        params = { "currency_pair" => "btc_jpy" }
      end

      api = post("active_orders", params )

      if !api.is_a?(Hash) or api["success"] != 1 then
        printf("etwings.tapi:gao error\n")
        p api
        return { :success => false }
      else
        ret = {}
        ret[:success] = true
        ret[:orders]  = []
        p api unless api["return"]
        api["return"].keys.each do |id|
          order = {}
          order[:id]        = id.to_i
          order[:type]      = api["return"][id]["action"] == "ask" ? "sell" : "buy"
          order[:price]     = BigDecimal.new(api["return"][id]["price"],10)
          order[:amount]    = BigDecimal.new(api["return"][id]["amount"],10)
          order[:timestamp] = api["return"][id]["timestamp"].to_i
          
          ret[:orders].push order
        end
      end
      return ret
    end

    def cancel_order( id )
      params = {
        "order_id" => id }
      api = post("cancel_order", params )

      if !api.is_a?(Hash) or api["success"] != 1 then
        printf("tapi:co %s\n",ret["error"] )
        return { :success => false }
      else
        return { :success => true }
      end
    end

    #
    # account情報を取得する
    #
    # 戻り値
    # { :success     => bool,
    #   :btc         => BigDecimal
    #   :jpy         => BigDecimal
    #   :open_orders => bool
    # }
    #
    def get_info
      params = {}
      begin
        api = post("get_info", params)
      rescue Timeout::Error
        printf "etwings::get_info Timeout::Error\n"
        return {:success => false}
      rescue => exc
        printf "exception in etwings::get_info\n"
        p exc
        return {:success => false}
      end

      if !api.is_a?(Hash) or api["success"] != 1 then
        p api
        return { :success => false }
      else
        p api if api["return"] == nil or api["return"]["funds"] == nil or api["return"]["funds"]["btc"] == nil
        p api if api["return"] == nil or api["return"]["funds"] == nil or api["return"]["funds"]["jpy"] == nil
        
        ret = {}
        ret[:success]     = true
        ret[:btc]         = BigDecimal.new(api["return"]["funds"]["btc"],10)
        ret[:jpy]         = BigDecimal.new(api["return"]["funds"]["jpy"],10)
        ret[:btc_ttl]     = BigDecimal.new(api["return"]["deposit"]["btc"],10)
        ret[:jpy_ttl]     = BigDecimal.new(api["return"]["deposit"]["jpy"],10)
        ret[:open_orders] = api["return"]["open_orders"] != 0
      end

      return ret
    end
  end

  class PublicApi
    #        attr_reader :uri
    attr_reader :response
    attr_reader :result
    def initialize
    end
    def get(uri)
      max_retry_count = 5
      url = URI.parse(uri)
      response = nil
      max_retry_count.times do |retry_count|
        http = Net::HTTP.new(url.host, url.port)
        http.use_ssl = true if (443==url.port)

        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.verify_depth = 5
        response = http.get( url.path )

        case response
        when Net::HTTPSuccess
          break
        when Net::HTTPRedirection
          url = URI.parse(response['Location'])
          next
        else
          break
        end
      end
      if response.code.to_i == 200
        @result = JSON.parse(response.body)
      else
        @result = nil
      end
      @response = response
      @result
    end

    def get_ticker( curr )
      begin
        if curr == :mona then
          get( "https://api.zaif.jp/api/1/ticker/mona_jpy" )
        else
          get( "https://api.zaif.jp/api/1/ticker/btc_jpy" )
        end
      rescue Timeout::Error
        printf "etwings::get_ticker Timeout::Error\n"
        return {"success" => 0}
      rescue => exc
        p exc
        return {"success" => 0}
      end
    end

    # last price
    # {
    #   :success => true/false
    #   :price   => last_price:BigDecimal
    # }
    def get_last_price( curr )
      begin
        if curr == :mona then
          api = get( "https://api.zaif.jp/api/1/last_price/mona_jpy" )
        else
          api = get( "https://api.zaif.jp/api/1/last_price/btc_jpy" )
        end
      rescue Timeout::Error
        printf "etwings::get_last_price Timeout::Error\n"
        return { :success => false }
      rescue => exc
        p exc
        return { :success => false }
      end

      
      ret = Hash.new
      if api.is_a?(Hash) and api["last_price"] then
        ret[:success] = true
        ret[:price] = BigDecimal.new( api["last_price"], 10 )
      else
        printf "etwings::get_last_price unexpected return value\n"
        p api
        ret[:success] = false
      end
      return ret
    end

    # 
    # 板情報を取得する
    # 戻り値
    # { :success   => bool
    #   :asks      => [ [ price:BigDecimal, amount:BigDecimal ] ]
    #  }
    def get_depth( curr )
      begin
        if curr == :mona then
          api = get( "https://api.zaif.jp/api/1/depth/mona_jpy" )
        else
          api = get( "https://api.zaif.jp/api/1/depth/btc_jpy" )
        end
      rescue Timeout::Error
        printf "etwings::get_depth Timeout::Error\n"
        return {"success" => false}
      rescue => exc
        p exc
        return {"success" => false}
      end

      ret = {}
      if api == nil then
        ret[:success] = false
      else
        ret[:success] = true
        ret[:asks] = []
        ret[:bids] = []

        if api['asks'].size > 0 then
          e = api['asks'][0]
          ret[:asks].push [ BigDecimal.new( e[0], Integer(Math::log(e[0],10))),
                            BigDecimal.new( e[1], Integer(Math::log(e[1],10))+8) ]
          end
        if api['bids'].size > 0 then
          e = api['bids'][0]
          ret[:bids].push [ BigDecimal.new( e[0], Integer(Math::log(e[0],10))),
                            BigDecimal.new( e[1], Integer(Math::log(e[1],10))+8) ]
        end
      end
      return ret
    end
  end
end
