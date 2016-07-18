# coding: utf-8
require 'rubygems'
require 'monkey-patch'
require 'yaml'
require 'bigdecimal'

require 'utils/BotUtils.rb'

require 'api/etwings.rb'
require 'api/coincheck.rb'
require 'api/bitflyer.rb'
require 'api/btcbox.rb'
require 'algorithm/Arbitrage.rb'
require 'algorithm/BitcoinBot.rb'

LOG_DIR = "./log/"
STAT_DIR = "./stat/"
ZF_STAT_FILE = STAT_DIR+"zf_status.yml"
CC_STAT_FILE = STAT_DIR+"cc_status.yml"


################################################################################
################################################################################

if $PROGRAM_NAME == __FILE__ then

  # read api key file
  if ARGV.size == 1 then
    KEY_FILE = ARGV[0]
    KEY = YAML::load File.open KEY_FILE if File.exist? KEY_FILE
  else
    puts "usage: ruby -I. Bot.rb \#{KEY YAML file}"
    exit
  end
  # create log file in ./log if it doesn't exit
  Dir.mkdir(LOG_DIR)  unless Dir.exists? LOG_DIR
  Dir.mkdir(STAT_DIR) unless Dir.exists? STAT_DIR

  #
  # zaifのapi accessor
  #
  tapi_zf = Etwings::TradeApi.new KEY['etwings']['PUB_KEY'], KEY['etwings']['SEC_KEY']
  papi_zf = Etwings::PublicApi.new
  rule_zf = {
    :fee           => 0.0,
    :ratioJPY      => 0.50,
    :ratioKP       => 0.03,                     # JPY持ち高目標
    :uVol          => BigDecimal.new("0.0001"),
    :uPrice        => BigDecimal.new("5.0"),
    :tSleep        => 1,   # seconds
    :tAverage      => 2*60*60 # seconds
  }

  #
  # coincheckのapi accessor
  #
  tapi_cc = CoinCheck::TradeApi.new KEY['coincheck']['PUB_KEY'], KEY['coincheck']['SEC_KEY']
  papi_cc = CoinCheck::PublicApi.new
  rule_cc = {
    :fee           => 0.0015,                       # 取引手数料
    :ratioJPY      => 0.50,                 # 1回あたりの買い高。JPY持ち高に対して
    :ratioKP       => 0.05,                     # JPY持ち高目標。暫定
    :uVol          => BigDecimal.new("0.005"),  # 最低 0.001, 単位 0.0001
    :uPrice        => BigDecimal.new("1.0"),
    :tSleep        => 5,   # seconds
    :tAverage      => 2*60*60 # seconds
  }

  #
  # bitFlyerのapi accessor
  #
  tapi_bf = BitFlyer::TradeApi.new KEY['bitFlyer']['PUB_KEY'], KEY['bitFlyer']['SEC_KEY']
  papi_bf = BitFlyer::PublicApi.new
  rule_bf = {
    :fee           => 0.0,                  # 取引手数料
    :ratioJPY      => 0.50,                 # 1回あたりの買い高。JPY持ち高に対して
    :ratioKP       => 0.05,                     # JPY持ち高目標。暫定
    :uVol          => BigDecimal.new("0.001"),  # 最低 0.001, 単位 0.00000001
    :uPrice        => BigDecimal.new("1.0"),
    :tSleep        => 5,   # seconds
    :tAverage      => 2*60*60 # seconds
  }

  #
  # btcbox
  #
  tapi_bb = BtcBox::TradeApi.new KEY['btcbox']['PUB_KEY'], KEY['btcbox']['SEC_KEY']
  papi_bb = BtcBox::PublicApi.new
  rule_bb = {
    :fee           => 0.0,                  # 取引手数料
    :ratioJPY      => 0.50,                 # 1回あたりの買い高。JPY持ち高に対して
    :ratioKP       => 0.05,                     # JPY持ち高目標。暫定
    :uVol          => BigDecimal.new("0.01"),   # 最低 0.01
    :uPrice        => BigDecimal.new("1.0"),
    :tSleep        => 5,   # seconds
    :tAverage      => 2*60*60 # seconds
  }
  
  #
  # Botの初期化
  #
  bot_arb = Arbitrage.new( {:name=>'zaif',     :papi=>papi_zf,:tapi=>tapi_zf,:rule=>rule_zf},
                           {:name=>'coincheck',:papi=>papi_cc,:tapi=>tapi_cc,:rule=>rule_cc},
                           {:name=>'bitFlyer', :papi=>papi_bf,:tapi=>tapi_bf,:rule=>rule_bf},
                           {:name=>'BtcBox',   :papi=>papi_bb,:tapi=>tapi_bb,:rule=>rule_bb},
                           LOG_DIR )

  # bot_arb = Arbitrage.new( {:name=>'zaif',     :papi=>papi_zf,:tapi=>tapi_zf,:rule=>rule_zf},
  #                          {:name=>'coincheck',:papi=>papi_cc,:tapi=>tapi_cc,:rule=>rule_cc},
  #                          {:name=>'bitFlyer', :papi=>papi_bf,:tapi=>tapi_bf,:rule=>rule_bf} )

  bot_zaif = BitcoinBot.new(tapi_zf, papi_zf, rule_zf, LOG_DIR, "zf", ZF_STAT_FILE, false)
  bot_bf   = BitcoinBot.new(tapi_cc, papi_cc, rule_cc, LOG_DIR, "cc", CC_STAT_FILE, false)

  count = 0
  while true do
    bot_arb.run
    sleep(3)

    #        bot_zaif.run
    #        sleep(3)
    #        bot_bf.run
    #        sleep(10)

    count += 1
    if count > 20 then
      count = 0
      $stdout.print "."
      $stdout.flush
    end
  end
end
