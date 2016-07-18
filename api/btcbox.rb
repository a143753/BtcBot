# coding: utf-8
require 'rubygems'
require 'json'
require 'net/http'
require 'net/https'
require 'openssl'
require 'uri'
require 'yaml'
require 'bigdecimal'
require 'resolv'

module BtcBox
  class TradeApi
    attr_reader :result
    attr_reader :response

    def initialize public_key, secret_key
      @public_key = public_key
      @secret_key = secret_key
      @result = nil
      @nonce = Time.new.to_i
    end

    def post(path, params)
      @nonce += 1
      params['key'] = @public_key
      params['nonce'] = @nonce.to_s

      hmac = OpenSSL::HMAC.new(Digest::MD5.hexdigest(@secret_key), OpenSSL::Digest::SHA256.new)
      params["signature"] = hmac.update( URI.encode_www_form(params) )

      uri = URI.parse("https://www.btcbox.co.jp" + path)
      
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      response = http.post(path, URI.encode_www_form(params))

      if response.code.to_i == 200
        @result = JSON.parse(response.body)
      else
        @result = nil
      end
      @result
    end

    def action_buy( curr, price, amount )
      if curr == :mona then
      else
        params = {
          "type"      => "buy",
          "price"     => Integer(price),
          "amount"    => amount }
        #                assert_equal(price, Integer(price))
      end
      api = post("/api/v1/trade_add", params )

      if !api.is_a?(Hash) or !api["result"] then
        printf("error in btcbox::action_buy\n")
        p params
        p api
        return false
      else
        return true
      end
    end

    def action_sell( curr, price, amount )
      if curr == :mona then
      else
        params = {
          "type"       => "sell",
          "price"      => Integer(price),
          "amount"     => amount }
      end

      api = post("/api/v1/trade_add", params )

      if !api.is_a?(Hash) or !api["result"] then
        printf("error in btcbox::action_sell\n")
        p params
        p api
        return false
      else
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
        params = {}
      else 
        params = { "type" => "open" }
      end

      api = post("/api/v1/trade_list", params )

      if !api.is_a?(Array) then
        printf("tapi:gao %s\n", api["error"] )
        return { :success => false }
      else

        ret = {}
        ret[:success] = true
        ret[:orders]  = []

        api.each do |e|
          order = {}

          order[:id]        = e["id"].to_i
          order[:type]      = e["type"]
          order[:price]     = BigDecimal.new(e["price"],10)
          order[:amount]    = BigDecimal.new(e["amount_outstanding"],10)
          order[:timestamp] = Time.new(e["datetime"]).to_i

          ret[:orders].push order
        end
      end
      return ret
    end

    def cancel_order( id )
      params = {
        "id" => id }
      api = post("/api/v1/trade_cancel", params )

      p api

      if !api.is_a?(Hash) or !api["result"] then
        printf("error in btcbox::cancel_order. id=%d\n", id)
        p api
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
        api = post("/api/v1/balance", params)
      rescue Timeout::Error
        printf "btcbox::get_info Timeout::Error\n"
        return {:success => false}
      rescue => exc
        p exc
        return {:success => false}
      end

      if !api.is_a?(Hash) then
        p api
        return { :success => false }
      else
        ret = {}
        ret[:success]     = true

        btc_balance = BigDecimal.new(api["btc_balance"], 10)
        btc_lock    = BigDecimal.new(api["btc_lock"],    10)
        jpy_balance = BigDecimal.new(api["jpy_balance"], 10)
        jpy_lock    = BigDecimal.new(api["jpy_lock"],    10)
        
        ret[:btc]         = btc_balance - btc_lock
        ret[:jpy]         = jpy_balance - jpy_lock
        ret[:btc_ttl]     = btc_balance
        ret[:jpy_ttl]     = jpy_balance
        ret[:open_orders] = get_active_orders(:btc)[:orders].size != 0
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
        begin
          @result = JSON.parse(response.body)
        rescue => exc
          printf "exception in btcbox::post\n"
          p exc
          @result = nil
          return @result
        end
      else
        @result = nil
      end
      @result
    end

    def get_ticker( curr )
      begin
        if curr == :mona then
          printf "btcbox::get_ticker BtcBox doesn't support mona"
          return {"success" => false}
        else
          api = get( "https://www.btcbox.co.jp/api/v1/ticker" )
        end
      rescue Timeout::Error
        printf "btcbox::get_ticker Timeout::Error\n"
        return {"success" => 0}
      rescue => exc
        p exc
        return {"success" => 0}
      end
      p api
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
          printf "btcbox::get_depth BtcBox doesn't support mona"
          return {"success" => false}
        else
          api = get( "https://www.btcbox.co.jp/api/v1/depth" )
        end
      rescue Timeout::Error
        printf "btcbox::get_depth Timeout::Error\n"
        return {"success" => false}
      rescue => exc
        p exc
        return {"success" => false}
      end

      ret = {}

      if !api.is_a?(Hash) or api['asks'] == nil or api['bids'] == nil then
        printf "btcbox:get_depth response was nil\n"
        ret[:success] = false
      else
        ret[:success] = true
        ret[:asks] = []
        ret[:bids] = []
        if api['asks'].size > 0 then
          e = api['asks'][0]
          ret[:asks].push [ BigDecimal.new( e[0], Integer(Math::log(e[0],10))),
                            BigDecimal.new( e[1], Integer(Math::log(e[1],10))+8) ]
        else
          ret[:success] == false
        end
        if api['bids'].size > 0 then
          e = api['bids'][0]
          ret[:bids].push [ BigDecimal.new( e[0], Integer(Math::log(e[0],10))),
                            BigDecimal.new( e[1], Integer(Math::log(e[1],10))+8) ]
        else
          ret[:success] == false
        end
      end
      return ret
    end
  end
end

if $0 == __FILE__ then

  KEY = YAML::load File.open '../src/key.yml' if File.exist? '../src/key.yml'

  tapi = BtcBox::TradeApi.new KEY['btcbox']['PUB_KEY'], KEY['btcbox']['SEC_KEY']
  papi = BtcBox::PublicApi.new

#  p papi.get_depth(:btc)

#  p tapi.get_active_orders(:btc)
  #p tapi.get_info
 p tapi.action_buy(:btc,  30000, 0.01 )
 p tapi.action_sell(:btc, 30000, 0.01 )
#    p tapi.cancel_order(10)
  

end
