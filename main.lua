PROJECT = "MQTT-LUAT-CLIENT"
VERSION = "1.0.0"

require "log"
LOG_LEVEL = log.LOGLEVEL_TRACE

require "sys"

require "net"
net.startQueryAll(60000,60000)

require "wdt"
wdt.setup(pio.P0_30, pio.P0_31)

require "netLed"
netLed.setup(true,pio.P1_1)

require "MqttLuatClient"
require "uart8032"

require "errDump"
errDump.request("udp://ota.airm2m.com:9072")

sys.init(0,0)
sys.run()