--- 模块功能：串口功能测试(TASK版)
-- @author openLuat
-- @module uart.testUartTask
-- @license MIT
-- @copyright openLuat
-- @release 2018.10.20
require "utils"
require "pm"
module(..., package.seeall)


-------------------------------------------- 配置串口 --------------------------------------------
-- 串口ID,串口读缓冲区
local UART_ID, sendQueue = 2, {}
-- 串口超时，串口准备好后发布的消息
--local uartimeout, recvReady = 50, "UART_RECV_ID"
local recvReady = "UART_RECV_ID"
local VoltageparameterREG --电压参数寄存器
local VoltageREG --电压寄存器
local CurrentParameterREG --电流参数寄存器
local CurrentREG --电流寄存器
VRMS = 0 --电压有效值
IRMS = 0 --电流有效值
--保持系统处于唤醒状态，不会休眠
pm.wake("mcuart")
uart.setup(UART_ID, 4800, 8, uart.PAR_EVEN, uart.STOP_1)
uart.on(2, "receive", function(uid, length)
    table.insert(sendQueue, uart.read(uid, length))
    sys.publish(recvReady)
-- sys.timerStart(sys.publish, uartimeout, recvReady)
end)

function inter(uid, length)
    table.insert(sendQueue, uart.read(uid, length))
    sys.publish(recvReady)
end

-- 解析串口收到的字符串
sys.subscribe(recvReady, function()
    local str = table.concat(sendQueue)
    local t = string.find(string.toHex(str), "5A")--判断第二位是否为5A
    local x1 = 0
    local x12 = 0
    if (t ~= nil) then
        --  log.info("t1=:", t)
        --log.info("t0 = :", string.toHex(str:sub(t - 2, t - 2)))
        x1 = string.toHex(str:sub(t - 2, t - 2))
        --log.info("x1=:", x1)
        if ((string.toHex(str:sub(t - 2, t - 2)) == "55") or (string.toHex(str:sub(t - 2, t - 2)) == "F2")) then --判断第一位是否为55
            local sum = 0
            for i = t, t + 20 do --检查校验和
                sum = sum + tonumber(string.toHex(str:sub(i, i)), 16)
            --    log.info("i[" .. i .. "]=" .. string.toHex(str:sub(i, i)))
            end
            sum = sum % 0x100
            --  log.info("sum is =: ", sum)
            if (sum == tonumber(string.toHex(str:sub(t + 21, t + 21)), 16)) then
                VoltageparameterREG = string.toHex(str:sub(t, t + 2))
                --log.info("VoltageparameterREG is ", VoltageparameterREG)
                VoltageREG = string.toHex(str:sub(t + 3, t + 5))
                --log.info("tVoltageREG =", VoltageREG)
                --log.info("tVoltageREG =", tonumber(VoltageREG, 16))
                VRMS = 2 * tonumber(VoltageparameterREG, 16) / tonumber(VoltageREG, 16)
                --log.info("VRMS =", VRMS)
                CurrentParameterREG = string.toHex(str:sub(t + 6, t + 8))
                --log.info("CurrentParameterREG is ", CurrentParameterREG)
                CurrentREG = string.toHex(str:sub(t + 9, t + 11))
                --log.info("CurrentREG is ", CurrentREG)
                IRMS = tonumber(CurrentParameterREG, 16) / (2 * tonumber(CurrentREG, 16))
                --log.info("RMS =", IRMS)
            end
        end
    end
    -- 串口写缓冲区最大1460
    for i = 1, #str, 1460 do
        uart.write(UART_ID, str:sub(i, i + 1460 - 1))
    end
    -- 串口的数据读完后清空缓冲区
    sendQueue = {}
end)
