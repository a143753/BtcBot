# coding: utf-8
require 'rubygems'
require 'json'
require 'net/http'
require 'net/https'
require 'openssl'
require 'uri'
require 'yaml'
require 'bigdecimal'

module BitFlyer
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

    def post(method, path, params)
      timestamp = Time.new.to_i
      uri = URI.parse format("https://api.bitflyer.jp%s", path)

      hmac = OpenSSL::HMAC.new(@secret_key, OpenSSL::Digest::SHA256.new)
      if method == "POST" then
        body = JSON.generate(params)
        digest = hmac.update(timestamp.to_s + method + path + body)
      else
        digest = hmac.update(timestamp.to_s + method + path)
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      headers = {
        'ACCESS-KEY'       => @public_key,
        'ACCESS-TIMESTAMP' => timestamp.to_s,
        'ACCESS-SIGN'      => digest.to_s,
        'Content-Type'     => 'application/json' }

      case method
      when "GET"
        begin
          response = http.start {
            http.get(uri.request_uri, headers)
          }
        rescue => exc
          p exc
          @result = nil
          return @result
        end
      when "POST"
        begin
          response = http.post(path, body, headers)
        rescue => exc
          printf "exception in BitFlyer::post\n"
          p exc
          @result = nil
          return @result
        end
      else
      end

      if response.code.to_i == 200
        if response.body != "" then
          begin
            @result = JSON.parse(response.body)
          rescue => exc
            printf "exception in bitFlyer::post\n"
            p exc
            p response.body
            @result = nil
          end
        else
          @result = nil
        end
      else
        p response
        p response.body
        @result = nil
      end
      @response = response
      @result
    end

    def action_buy( curr, price, amount )
      if curr == :mona then
        # ask mona売り bid mona買い
        raise "aho"
      #                assert_equal(amount, Integer(amount))
      else
        params = {
          "product_code"     => "BTC_JPY",
          "child_order_type" => "LIMIT", # 指値
          "side"             => "BUY",
          "price"            => Integer(price),
          "size"             => amount }
        #                assert_equal(price, Integer(price))
      end
      
      ret = post("POST", "/v1/me/sendchildorder", params )

      if !ret.is_a?(Hash) then
        printf("tapi:ab error\n")
        p ret
        return false
      else
        return true
      end
    end

    def action_sell( curr, price, amount )
      if curr == :mona then
        # ask mona売り bid mona買い
        raise "aho"
      else
        params = {
          "product_code"     => "BTC_JPY",
          "child_order_type" => "LIMIT", # 指値
          "side"             => "SELL",
          "price"            => Integer(price),
          "size"             => amount }
      end

      ret = post("POST", "/v1/me/sendchildorder", params )
      
      if !ret.is_a?(Hash) then
        printf("tapi:as unexpected response\n")
        p ret
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
        raise "aho"
      else 
        # params = { "product_code" => 'BTC_JPY',
        #            "count" => 10,
        #            "parent_order_state" => "ACTIVE" }
        params = { "product_code" => 'BTC_JPY',
                   "child_order_state" => "ACTIVE"
                 }
      end

      query = params.map { |k,v| "#{k}=#{v}" }.join("&")
      api = post("GET", "/v1/me/getchildorders/?" + query, params)

      if !api.is_a?(Array) then
        printf("bitFlyer.get_active_orders. api error. response was not array.\n")
        p api
        p params
        p query
        return { :success => false }
      else
        ret = {}
        ret[:success] = true
        ret[:orders]  = []
        api.each do |e|
          order = {}
          order[:id]        = e["id"]
          order[:type]      = e["side"].downcase
          order[:price]     = BigDecimal.new(e["price"],10)
          order[:amount]    = BigDecimal.new(e["size"],10)
          order[:timestamp] = Time.iso8601(e["child_order_date"]).to_i
          ret[:orders].push order
        end
      end
      return ret
    end

    def cancel_order( id )
      params = {
        "product_code" => "BTC_JPY",
        "child_order_id" => id }

      api = post("POST", "/v1/me/cancelchildorder", params )

      if api == nil then
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
        api = post("GET", "/v1/me/getbalance", params)
      rescue Timeout::Error
        printf "bitFlyer::get_info Timeout::Error\n"
        return {:success => false}
      rescue => exc
        p exc
        return {:success => false}
      end

      if !api.is_a?(Array) then
        return { :success => false }
      else
        ret = {}
        ret[:success]     = true

        api.each do |e|
          case e["currency_code"]
          when "JPY"
            ret[:jpy]     = BigDecimal.new(e["available"],10)
            ret[:jpy_ttl] = BigDecimal.new(e["amount"],10)
          when "BTC"
            ret[:btc]     = BigDecimal.new(e["available"],10)
            ret[:btc_ttl] = BigDecimal.new(e["amount"],10)
          when "ETH"
            ;
          else
            ret[:success] = false
          end
        end
      end

      r = get_active_orders(:btc)
      ret[:open_orders] = (r[:orders] != [])

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

    # 
    # 板情報を取得する
    # 戻り値
    # { :success   => bool
    #   :asks      => [ [ price:BigDecimal, amount:BigDecimal ] ]
    #  }
    def get_depth( curr )
      begin
        if curr == :mona then
          raise "aho"
        else
          api = get( "https://api.bitflyer.jp/v1/getboard" )
        end
      rescue Timeout::Error
        printf "bitFlyer::get_depth Timeout::Error\n"
        return {"success" => false}
      rescue => exc
        p exc
        return {"success" => false}
      end

      ret = {}
      if !api.is_a?(Hash) or api['asks'] == nil or api['bids'] == nil then
        printf "\nbitflyer:get_depth response was nil\n"
        ret[:success] = false
      elsif api['asks'][0]["price"] < api['bids'][0]["price"] then
        printf "\nbitflyer:suspicious result(0) "
        printf( "asks %f, bids %f\n", api['asks'][0]["price"], api['bids'][0]["price"] )
        ret[:success] = false
      elsif api['asks'][0]["price"] < 30000 or api['bids'][0]["price"] < 30000 then
        printf "\nbitflyer:suspicious result(1) "
        printf( "asks %f, bids %f\n", api['asks'][0]["price"], api['bids'][0]["price"] )
        ret[:success] = false
      else
        ret[:success] = true
        ret[:asks] = []
        ret[:bids] = []

        if api['asks'].size > 0 then
          e = api['asks'][0]

          if e["price"] > 0 and e["size"] > 0 then
            begin
              bp = BigDecimal.new( e["price"], Integer(Math::log(e["price"],10)))
              bs = BigDecimal.new( e["size"],  Integer(Math::log(e["size"], 10))+8)
            rescue => exc
              printf "exception in bitFlyer.get_depth"
              p e
              ret[:success] = false
              return ret
            end
          else
            printf "error in bitFlyer.egt_depth"
            printf "e[\"price\"] = %f, e[\"size\"] = %f\n", e["price"], e["size"]
            ret[:success] = false
          end

          if bp > 0 and bs > 0 then
            begin
              ret[:asks].push [ bp, bs ]
            rescue => exc
              printf "exception in bitFlyer.egt_depth"
              p exc
              p e["price"]
              p e["size"]
              p BigDecimal.new( e["price"], Integer(Math::log(e["price"],10)))
              p BigDecimal.new( e["size"], Integer(Math::log(e["size"],10))+8)
              ret[:success] = false
              return ret
            end
          else
            printf "\nbitflyer:suspicious result(2)"
            p api
            ret[:success] = false
              return ret
          end
        end
        if api['bids'].size > 0 then
          e = api['bids'][0]

          if e["price"] > 0 and e["size"] > 0 then
            begin
              bp = BigDecimal.new( e["price"], Integer(Math::log(e["price"],10)))
              bs = BigDecimal.new( e["size"], Integer(Math::log(e["size"],10))+8)
            rescue => exc
              printf "exception in bitFlyer.get_depth"
              p e
              ret[:success] = false
              return ret
            end
          else
            printf "error in bitFlyer.egt_depth"
            printf "e[\"price\"] = %f, e[\"size\"] = %f\n", e["price"], e["size"]
            ret[:success] = false
            return ret
          end

          if bp > 0 and bs > 0 then
            begin
              ret[:bids].push [ bp, bs ]
            rescue => exc
              printf "exception in bitFlyer.get_depth"
              p exc
              p e["price"]
              p e["size"]
              p BigDecimal.new( e["price"], Integer(Math::log(e["price"],10)))
              p BigDecimal.new( e["size"], Integer(Math::log(e["size"],10))+8)
              ret[:success] = false
              return ret
            end
          else
            printf "\nbitflyer:suspicious result(3)"
            p api
            ret[:success] = false
            return ret
          end
        end
      end
      return ret
    end
  end
end

if $0 == __FILE__ then

  
  KEY = YAML::load File.open '../src/key.yml' if File.exist? '../src/key.yml'

  tapi = BitFlyer::TradeApi.new KEY['bitFlyer']['PUB_KEY'], KEY['bitFlyer']['SEC_KEY']
  papi = BitFlyer::PublicApi.new

  p papi.get_depth(:btc)

#  p tapi.get_info
#  p tapi.get_active_orders(:btc)
#  p tapi.action_buy(:btc, 30000, 0 )
#  p tapi.action_sell(:btc, 30000, 0 )
#  p tapi.cancel_order(0)

end
