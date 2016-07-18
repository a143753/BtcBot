# -*- coding: utf-8 -*-
# programで保持する値
require 'rubygems'
require 'json'
require 'monkey-patch'
require 'net/http'
require 'net/https'
require 'openssl'
require 'uri'
require 'yaml'
require 'etwings.rb'

class MonaBot

    def initialize tapi, papi, sim_mode = true
        @SIM_MODE = sim_mode
        @tapi = tapi
        @papi = papi

        @as = {
            :vMona    => 20,  # mona持ち高. 値はtest用
            :vJPY     => 1000 # JPY持ち高. 値はtest用
        }
        loadTradeStatus

        @recentHigh = 0
        @R = {
            :fee           => 0.0,
            :ratioJPY	   => 0.03,
            :thBuy         => 0.98,
            :thExtraBuy    => 0.98,
            :thSell        => 1.02
        }
    end

    def loadTradeStatus
        if File.exist? "../dat/status.yml"
            @ts = YAML::load File.open "../dat/status.yml"
        else
            raise
        end
    end

    def saveTradeStatus
        YAML.dump( @ts, File.open("../dat/status.yml", "w") )
    end

    def updateAccount
        if @SIM_MODE == false
            res = @tapi.get_info
            if res["success"] != 1 then
                printf("API Error.\n")
                return false
            end

            if res["return"]["open_orders"] != 0 then
                printf "as: cancel order\n"
                cancelOrder
                return false
            end

            @as[:vMona] = res["return"]["funds"]["mona"]
            @as[:vJPY]  = res["return"]["funds"]["jpy"]
        end
        printf("as: vMona=%f, vJPY=%f, avg=%f\n", @as[:vMona], @as[:vJPY], calcAverage )
        return true
    end

    def getMarketInfo
        while true do
            @depth  = @papi.get_depth
            break if @depth
            sleep(2)
        end

        if @depth["asks"][0][0] > @recentHigh then
            @recentHigh = @depth["asks"][0][0]
        end
        printf("mi: asks=[%f,%d], bids=[%f,%d], recentHigh=%f, avg=%f\n",
               @depth["asks"][0][0],@depth["asks"][0][1],
               @depth["bids"][0][0],@depth["bids"][0][1],
               @recentHigh,
               calcAverage)
               
    end

    def calcAverage
        if @ts["TTLJPY"] == 0 then
            avg = 0
        else 
            # 端数分が儲けに見えるので avgから1.0を引く
            avg = @ts["TTLJPY"].to_f / @ts["TTLMONA"].to_f
        end
#        printf( "calcAverage: balance=%f, @vMona=%f avg=%f\n", @ts["TTLJPY"], @as[:vMona], avg )
        return avg
    end

    def judgeSell
        # monaを売る判定
        judge = false
        avg   = 0
        if @as[:vMona] < 1.0 then
            judge = false
        else
            # 現在のmonaの平均買付価格
            # 平均買付価格はゼロにもマイナスにもなる
            avg   = calcAverage 
            judge = (@depth["bids"][0][0] > avg * @R[:thSell]) and (@depth["bids"][0][0] < @recentHigh)
        end
        printf( "js: vMona=%f, bids=%f, th=%f, judge=%s\n", 
                @as[:vMona], @depth["bids"][0][0], avg * @R[:thSell], judge )
        return judge
    end

    def judgeBuy
        # monaを買う判定
        judge = false
        avg   = calcAverage 
        if @depth["asks"][0][0] <  avg * @R[:thBuy] then
            judge = true
        else
            if (@ts["TTLJPY"] == 0) and (@depth["asks"][0][0] < @recentHigh * @R[:thExtraBuy]) then
                judge = true
            else
                judge = false
            end
        end
        printf( "jb: vJPY=%f,asks=%f,thBuy=%f,rH=%f,judge=%s\n",
                @as[:vJPY],@depth["asks"][0][0],avg * @R[:thBuy],@recentHigh * @R[:thExtraBuy],judge)
        return judge
    end

    

    def actionBuy
        # 売買するmonaは1mona単位
        # price(JPY/MONA)は0.1円単位

        price = @depth["asks"][0][0]

        # if @as[:vJPY] < @R[:unitJPY] then
        #     volJpy = 0
        # elsif @as[:vJPY] * @R[:ratioJPY] < @R[:unitJPY] then
        #     volJpy = @R[:unitJPY]
        # else
        #     volJpy = Integer(@as[:vJPY] * @R[:ratioJPY] / @R[:unitJPY] ) * @R[:unitJPY]
        # end

        volJpy = ( @as[:vJPY] * @R[:ratioJPY] / price ).ceil # mona

        if volJpy > @depth["asks"][0][1]
            vol = @depth["asks"][0][1]
        else
            vol = Integer(volJpy)
        end

        printf("volJpy=%f,vol=%f\n",volJpy,vol)

        if @SIM_MODE then
            printf(" buy  %f mona at %f\n", vol, price )
            @as[:vMona]    += vol
            @as[:vJPY]     -= vol * price
        else
            @tapi.action_buy( price, vol )
        end
        @ts["TTLJPY"]  += vol * price
        @ts["TTLMONA"] += vol
        @recentHigh = @depth["asks"][0][0]

        saveTradeStatus unless vol == 0
    end

    def actionSell
        # 売買するmonaは1mona単位
        # price(JPY/MONA)は0.1円単位

        price = @depth["bids"][0][0]

        if @as[:vMona] < 1.0 then
            volMona = 0
        else
            volMona = Integer( @as[:vMona] / 1.0 ) * 1.0
        end

        if volMona > @depth["bids"][0][1]
            vol = @depth["bids"][0][1]
        else
            vol = volMona
        end
        printf("se: volMona=%f, vol=%f\n", volMona, vol)


        if @SIM_MODE then
            printf(" sell %f mona at %f\n", vol, price )
            @as[:vMona]    -= vol
            @as[:vJPY]     += vol * price
        else
            @tapi.action_sell( price, vol )
        end
        if vol == volMona then
            @ts["TTLJPY"]  = 0
            @ts["TTLMONA"] = 0
        else
            @ts["TTLJPY"]  -= vol * price
            @ts["TTLMONA"] -= vol
        end
        @recentHigh = @depth["asks"][0][0]

        saveTradeStatus unless vol == 0
    end

    def cancelOrder
        sleep(2)
        ids = @tapi.get_active_orders

        ids.each do |id|
            sleep(2)
            @tapi.cancel_order(id)
        end
    end

    def run
        if updateAccount then
            sleep(2)

            getMarketInfo
            sleep(2) 
            
            if judgeSell then
                actionSell
            elsif judgeBuy then
                actionBuy
            end
        end
        sleep(60)
    end
end


######################################################################
######################################################################
######################################################################

if $0 == __FILE__ then

    if File.exist? "key.yml"
        KEY = YAML::load File.open "key.yml"
    end

    tapi = Etwings::TradeApi.new KEY["etwings"]["PUB_KEY"], KEY["etwings"]["SEC_KEY"] 
    papi = Etwings::PublicApi.new
    bot = MonaBot.new( tapi, papi, false )

    while true do    
        bot.run
    end
end
