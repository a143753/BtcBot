# coding: utf-8
# coding: utf-8
require 'rubygems'
require 'json'
require 'net/http'
require 'net/https'
require 'openssl'
require 'uri'
require 'yaml'
require 'bigdecimal'

require 'time'
module CoinCheck
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

    def post(type, method, params)
      @nonce += 1
      
      path = format("/api/%s", method)
      uri  = URI.parse format("https://coincheck.jp%s", path)

      hmac = OpenSSL::HMAC.new(@secret_key, OpenSSL::Digest::SHA256.new)
      param = params.map { |k,v| "#{k}=#{v}" }.join("&")
      digest = hmac.update(@nonce.to_s+uri.to_s+param)

      headers = {
        'ACCESS-KEY' => @public_key,
        'ACCESS-NONCE' => @nonce.to_s,
        'ACCESS-SIGNATURE' => digest.to_s }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 300
      http.read_timeout = 300
      http.ssl_timeout  = 300

      begin
        if type == :get then
          response = http.start {
            http.get(uri.request_uri, headers)
          }
        elsif type == :post then
          response = http.post(path, URI.escape(param), headers)
        elsif type == :delete then
          response = http.start {
            http.delete(uri.request_uri, headers)
          }
        else
          raise
        end
      rescue => exc
        printf "exception in coincheck.rb\n"
        p exc
        @result = nil
        return @result
      end

      if response.code.to_i == 200 || response.code.to_i == 400
        @result = JSON.parse(response.body)
      else
        @result = { "error" => response.code.to_i }
        p response.body
      end
      @response = response
      @result
    end

    # 買い注文
    # 戻り値 : bool
    def action_buy( curr, price, amount )
      if curr == :mona then
        raise
      else
        params = {
          "pair"          => "btc_jpy",
          "order_type"    => "buy",
          "rate"          => Integer(price),
          "amount"        => amount }
      end
      ret = post( :post, "exchange/orders", params )
      if !ret.is_a?(Hash) or ret["success"] != true then
        printf("tapi:ab %s\n",ret["error"] )
        return false
      else
        return true
      end
    end

    def action_sell( curr, price, amount )
      if curr == :mona then
        raise
      else
        params = {
          "pair"         => "btc_jpy",
          "order_type"   => "sell",
          "rate"         => Integer(price),
          "amount"       => amount }
      end
      ret = post( :post, "exchange/orders", params )
      if !ret.is_a?(Hash) or ret["success"] != true then
        printf("tapi:ab %s\n",ret["error"] ) if ret != nil
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
      api = post( :get, "exchange/orders/opens", params )

      # APIからの戻り値
      # {"success"=>true, "orders"=>[]}
      
      if !api.is_a?(Hash) or api["success"] != true then
        printf("tapi:gao %s\n",api.to_s )
        return { :success => false }
      else
        ret = {}
        ret[:success] = api["success"]
        ret[:orders]  = []
        api["orders"].each do |o|

          order = {}
          order[:id]        = o["id"]
          order[:type]      = o["order_type"]
          order[:price]     = BigDecimal.new(o["rate"])
          order[:amount]    = BigDecimal.new(o["pending_amount"])
          order[:timestamp] = Time.parse(o["created_at"]).to_i
          
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
      #      params = { "id" => id }
      params = {} # hashにIDを入れるとAPI error
      api = post( :delete, "exchange/orders/#{id}", params )
      
      if !api.is_a?(Hash) or api["success"] != true or api["id"] != id then
        printf("tapi:co %s\n",api.to_s )
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
    #   :btc         => BigDecimal  売買可能な残高
    #   :jpy         => BigDecimal  売買可能な残高
    #   :btc_ttl     => BigDecimal  未決オーダー分含む
    #   :jpy_ttl     => BigDecimal  未決オーダー分含む
    #   :open_orders => bool
    # }
    #
    def get_info

      params = {}
      begin
        api = post( :get, "accounts/balance", params)
      rescue Timeout::Error
        printf "CoinCheck::get_info Timeout::Error\n"
        return {:success => false}
      rescue => exc
        p exc
        return {:success => false}
      end

      if !api.is_a?(Hash) or api["success"] != true
        p api
        return { :success => false }
      else
        ret = {}
        ret[:success]     = true
        ret[:btc]         = BigDecimal.new(api["btc"])
        ret[:jpy]         = BigDecimal.new(api["jpy"])
        ret[:btc_ttl]     = ret[:btc] + BigDecimal.new(api["btc_reserved"])
        ret[:jpy_ttl]     = ret[:jpy] + BigDecimal.new(api["jpy_reserved"])
        ret[:open_orders] = ( (api["jpy_reserved"].to_f!=0) or (api["btc_reserved"].to_f!=0) )
        return ret
      end
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
        http.open_timeout = 300
        http.read_timeout = 300
        http.ssl_timeout  = 300

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
          printf "exception in coincheck::post\n"
          p exc
          @result = nil
          return @result
        end          
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
          raise
        else
          api = get( "https://coincheck.jp/api/order_books" )
        end
      rescue Timeout::Error
        printf "CoinCheck::get_depth Timeout::Error\n"
        return {:success => false}
      rescue => exc
        p exc
        return {:success => false}
      end

      if !api.is_a?(Hash) then
        return { :success => false }
      else
        ret = {}
        ret[:success] = true
        ret[:asks] = []
        ret[:bids] = []

        if api['asks'].size > 0 then
          e = api['asks'][0]
          ret[:asks].push [ BigDecimal.new(e[0]), BigDecimal.new(e[1]) ]
        end
        if api['bids'].size > 0 then
          e = api['bids'][0]
          ret[:bids].push [ BigDecimal.new(e[0]), BigDecimal.new(e[1]) ]
        end
        return ret
      end
    end
  end
end


if $0 == __FILE__ then
  
  KEY = YAML::load File.open '../src/key.yml' if File.exist? '../src/key.yml'

  tapi = CoinCheck::TradeApi.new KEY['coincheck']['PUB_KEY'], KEY['coincheck']['SEC_KEY']
  papi = CoinCheck::PublicApi.new

#  p papi.get_depth(:btc)

  ret = tapi.get_info

  p ret[:jpy].to_f
  p ret[:jpy_ttl].to_f
  p ret[:btc].to_f
  p ret[:btc_ttl].to_f
  
#  p tapi.get_active_orders(:btc)
#  p tapi.action_buy(:btc, 30000, 0 )
#  p tapi.action_sell(:btc, 30000, 0 )
#  p tapi.cancel_order(0)

end
