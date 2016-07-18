# coding: utf-8

module Bitfinex
  class TradeApi
    def initialize public_key, secret_key
      @public_key = public_key
      @secret_key = secret_key
      @response = nil
      @result = nil
      @nonce = Time.new.to_i
    end

    def post(type, method, params)
      @nonce += 1

      params["request"] = format("/v1/%s",method)
      params["nonce"]   = @nonce.to_s
      
      uri  = URI.parse format("https://api.bitfinex.com/v1/%s", method)

      hmac = OpenSSL::HMAC.new(@secret_key, OpenSSL::Digest::SHA384.new)
      payload = Base64.strict_encode64(params.to_json)
      signature = hmac.update(payload).hexdigest

      headers = {
        'X-BFX-APIKEY'    => @public_key,
        'X-BFX-PAYLOAD'   => payload,
        'X-BFX-SIGNATURE' => signature }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      if type == :get then
        begin 
          response = http.start {
            http.get(uri.request_uri, headers)
          }
        rescue OpenSSL::SSL::SSLError
          printf "Bitfinex::post OpenSSL::SSL::SSLError\n"
          @result = nil
          return @result
        rescue => exc
          p exc
          @result = nil
          return @result
        end
      elsif type == :post then
        begin
          response = http.post(uri.path, URI.escape(payload), headers)
        rescue OpenSSL::SSL::SSLError
          printf "Bitfinex::post OpenSSL::SSL::SSLError\n"
          @result = nil
          return @result
        rescue => exc
          p exc
          @result = nil
          return @result
        end
      elsif type == :delete then
        begin
          response = http.start {
            http.delete(uri.request_uri, headers)
          }
        rescue OpenSSL::SSL::SSLError
          printf "Bitfinex::post OpenSSL::SSL::SSLError\n"
          @result = nil
          return @result
        rescue => exc
          p exc
          @result = nil
          return @result
        end
      else
        raise
      end

      if response.code.to_i == 200 || response.code.to_i == 400
        @result = JSON.parse(response.body)
      else
        printf("unexpected response %d\n", response.code.to_i)
        p response
        @result = nil
      end
      @response = response
      @result
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

      # wallet info
      params = {}
      begin
        api = post( :post, "balances", params)
      rescue Timeout::Error
        printf "CoinCheck::get_info Timeout::Error\n"
        return {:success => false}
      rescue => exc
        p exc
        return {:success => false}
      end

      if !api.is_a?(Array) or !api[0].is_a?(Hash) then
        p api
        return { :success => false }
      else
        ret = {}
        ret[:success]     = true
        api.each do |e|
          if e["type"] == "exchange" then
            if e["currency"] == "usd" then
              ret[:usd] = BigDecimal.new(e["available"])
            elsif e["currency"] == "btc" then
              ret[:btc] = BigDecimal.new(e["available"])
            end
          end
        end
      end

      # open orderの取得
      params = {}
      begin
        api = post( :post, "orders", params)
      rescue Timeout::Error
        printf "CoinCheck::get_info Timeout::Error\n"
        return {:success => false}
      rescue => exc
        p exc
        return {:success => false}
      end

      if !api.is_a?(Array) then
        p api
        return { :success => false }
      else
        ret[:open_orders] = ( api.size > 0 )
      end

      return ret
    end

    # 買い注文
    # 戻り値 : bool
    def action_buy( curr, price, amount )
      if curr == :btc then
        params = { "request"  => "order/new",
                   "symbol"   => "btcusd",
                   "amount"   => amount.to_s,
                   "price"    => price.to_s,
                   "exchange" => "bitfinex",
                   "side"     => "buy",
                   "type"     => "exchange market" }
      else
        raise
      end

      ret = post( :post, "order/new", params )
      if !ret.is_a?(Hash) or ret["message"] then
        printf("tapi:ab %s, %f, %f\n",ret["message"], price, amount )
        return false
      else
        return true
      end
    end

    def action_sell( curr, price, amount )
      if curr == :btc then
        params = { "request"  => "order/new",
                   "symbol"   => "btcusd",
                   "amount"   => amount.to_s,
                   "price"    => price.to_s,
                   "exchange" => "bitfinex",
                   "side"     => "sell",
                   "type"     => "exchange limit" }
      else
        raise
      end
      ret = post( :post, "order/new", params )
      if !ret.is_a?(Hash) or ret["message"] then
        printf("tapi:ab %s\n",ret["message"] )
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
      raise unless curr == :btc

      params = {}
      api = post( :get, "orders", params )

      # APIからの戻り値
      # {"success"=>true, "orders"=>[]}

      if !api.is_a?(Array) then
        p api
        return { :success => false }
      else
        ret = {}
        ret[:success] = true
        ret[:orders]  = []
        api.each do |o|

          order = {}
          order[:id]        = o["order_id"]
          order[:type]      = o["side"]
          order[:price]     = BigDecimal.new(o["price"])
          order[:amount]    = BigDecimal.new(o["remaining_amount"])
          order[:timestamp] = o["timestamp"].to_i
          
          ret[:orders].push order
        end
        return ret
      end
    end

    #
    # orderをcancelする
    #
    # 戻り値
    # ret { :success  => bool }
    #
    def cancel_order( id )
      params = { "order_id" => id }
      api = post( :post, "order/cancel", params )
      if !api.is_a?(Hash) or api["message"] then
        printf("tapi:co %s\n",api["message"])
        return { :success => false }
      else
        return { :success => true }
      end
    end
  end

  class PublicApi
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
        begin
          response = http.get( url.path )
        rescue => exc
          p exc
          @result = nil
          return
        end

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

    def get_depth( curr )
      if curr == :btc then
        api = get( "https://api.bitfinex.com/v1/book/btcusd" )
      else
        raise
      end

      if !api.is_a?(Hash) or !api["bids"].is_a?(Array) or !api["asks"].is_a?(Array) then
        p api
        return { :success => false }
      else
        ret = {}
        ret[:success] = true
        ret[:asks] = []
        ret[:bids] = []

        if api['bids'].size > 0 then
          e = api["bids"][0]
          ret[:bids].push [ BigDecimal.new(e["price"]), BigDecimal.new(e["amount"]) ]
        end
        if api['asks'].size > 0 then
          e = api["asks"][0]
          ret[:asks].push [ BigDecimal.new(e["price"]), BigDecimal.new(e["amount"]) ]
        end
        return ret
      end
    end
  end

    # class API
    #     class << self
    #         def get_https(opts={})
    #             raise ArgumentError, "Bitfinex" if not opts[:url].is_a? String
    #             uri = URI.parse opts[:url]
    #             http = Net::HTTP.new uri.host, uri.port
    #             http.use_ssl = true
    #             http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    #             if opts[:params].nil?
    #                 request = Net::HTTP::Get.new uri.request_uri
    #             else
    #                 # If sending params, then we want a post request for authentication.
    #                 request = Net::HTTP::Post.new uri.request_uri
    #                 request.add_field "X-BFX-APIKEY", opts[:key]
    #                 request.add_field "X-BFX-PAYLOAD", opts[:params_enc]
    #                 request.add_field "X-BFX-SIGNATURE", opts[:signed]
    #             end
    #             response = http.request request
    #             response.body
    #         end

    #     end
    #     def self.get_json(opts={})
    #         result = get_https(opts)
    #         if not result.is_a? String or not result.valid_json?
    #             raise RuntimeError, "Server returned invalid data."
    #         end
    #         JSON.load result
    #     end
    #     def self.sign(params,sec_key)
    #         hmac = OpenSSL::HMAC.new(sec_key, OpenSSL::Digest::SHA384.new)
    #         hmac.update( params )
    #         signed = hmac.hexdigest
    #         return signed
    #     end
    # end

    # class Bot
    #     include Test::Unit::Assertions
    #     API_URL = "https://api.bitfinex.com"
    #     API_VER = "/v1"
    #     APIs = {
    #         "balances" => :private,
    #         "book"     => :public,
    #         "order/new"=> :private
    #     }
    #     MIN_AMOUNT = {
    #         :ltc      => 0.001,
    #         :btc      => 0.0
    #     }
    #     PairTable = {
    #         "LTC/BTC" => "ltcbtc"
    #     }
    #     def pairStr( pair )
    #         if PairTable.keys.include? pair then
    #             return PairTable[pair]
    #         else
    #             raise ArgumentError, "unknown currency pair "+pair
    #         end
    #     end

    #     def initialize pair, key
    #         @last_nonce = 1.1
    #         @name = "Bitfinex"
    #         @pair = pairStr(pair)
    #         @PUB_KEY = key["PUB_KEY"]
    #         @SEC_KEY = key["SEC_KEY"]

    #         @address = {
    #             :btc => key["ADDRBTC"],
    #             :ltc => key["ADDRLTC"]
    #         }

    #         @trans_fee_btc = 0.0005
    #         @trans_fee_ltc = 0.02
    #     end
    #     def getTradingFees
    #         @fee = 0.15 / 100
    #     end
    #     def getMinimumAmount( cur )
    #         return MIN_AMOUNT[cur]
    #     end
    #     def updateAccount
    #         ret = call( @pair, "balances", {"request"=>"#{API_VER}/balances", "nonce"=>nonce} )

    #         @balance = {:usd =>0, :btc =>0, :ltc => 0 }
    #         ret.each do |r|
    #             if r["type"] == "exchange" then
    #                 case(r["currency"])
    #                 when "usd"
    #                     @balance[:usd] = r["available"].to_f
    #                 when "btc"
    #                     @balance[:btc] = r["available"].to_f
    #                 when "ltc"
    #                     @balance[:ltc] = r["available"].to_f
    #                 else
    #                     raise "unexpected currency "+r["type"]
    #                 end
    #             end
    #         end
    #     end
    #     # 買い注文を発行する
    #     #[price] 購入価格(BTC)
    #     #[amount] 購入量(LTC)
    #     def orderBuy( price, amount )
    #         params = { "request"  => "#{API_VER}/order/new",
    #                                           "nonce"    => nonce,
    #                                           "symbol"   => @pair,
    #                                           "amount"   => amount.to_s,
    #                                           "price"    => price.to_s,
    #                                           "exchange" => "bitfinex",
    #                                           "side"     => "buy",
    #                                           "type"     => "market" }

    #         ret = call( @pair, "order/new", params )
    #         p @name
    #         p params
    #         p ret
    #     end

    #     # 売り注文を発行する
    #     #[price] 売却価格(BTC)
    #     #[amount] 売却量(LTC)
    #     def orderSell (price, amount )
    #         params = { "request"  => "#{API_VER}/order/new",
    #                                           "nonce"    => nonce,
    #                                           "symbol"   => @pair,
    #                                           "amount"   => amount.to_s,
    #                                           "price"    => price.to_s,
    #                                           "exchange" => "bitfinex",
    #                                           "side"     => "sell",
    #                                           "type"     => "market" }
    #         ret = call( @pair, "order/new", params )
    #         p @name
    #         p params
    #         p ret
    #     end

    #     def transfer( cur, amount, dest )
    #         address = dest.address[cur]
    #         printf("[Info] %s doesn't support transfer API\n", @name )
    #     end

    #     def api_url( method, pair )
    #         case method
    #         when "balances", "order/new"
    #             return format("%s%s/%s", API_URL, API_VER, method )
    #         when "book"
    #             return format("%s%s/%s/%s", API_URL, API_VER, method, pair )
    #         else
    #             raise ArgumentError, "unknown method "+method

    #         end
    #     end

    #     def call( pair, method, params )
    #         if APIs[method] == :public then
    #             if params == {} then
    #                 API.get_json({ :url => api_url(method,pair) })
    #             else
    #                 API.get_json({ :url => api_url(method,pair),
    #                                        :params => params })
    #             end
    #         elsif APIs[method] == :private then
    #             url = api_url(method,pair)
    #             params_enc = Base64.strict_encode64(params.to_json)
    #             signed = API.sign( params_enc, @SEC_KEY )
    #             if params == {} then
    #                 API.get_json({ :url => api_url(method,pair) })
    #             else
    #                 API.get_json({ :url => api_url(method,pair),
    #                                :key => @PUB_KEY,
    #                                :params => params,
    #                                :params_enc => params_enc,
    #                                :signed => signed })
    #             end
    #         else
    #             assert( false, format("unknown method %s",method) )
    #         end
    #     end
    #     def nonce
    #         while result = Time.now.to_i and @last_nonce and @last_nonce >= result
    #             sleep 1
    #         end
    #         @last_nonce = result
    #         # Bitfinexではnonceは文字列型でなければならない
    #         return result.to_s
    #     end
    #     private :nonce
    #     attr_reader :ask, :bid, :fee, :name, :balance, :address
    # end

end

if $0 == __FILE__ then
    if File.exist? "key.yml"
        KEY = YAML::load File.open "key.yml"
    end
    b = Bitfinex::Ticker.new( "ltcbtc", KEY["Bitfinex"] )
    p b.ticker
end
