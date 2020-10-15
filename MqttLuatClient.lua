module(..., package.seeall)

require "mqtt"
require "utils"
require "pm"
require "misc"
require "pins"
require "config"
require "nvm"
require "ntp"
require "uart8032"
nvm.init("config.lua")

local MqttIp, MqttPort, MqttUser, MqttPassword = "47.103.4.35", 1883
local argsQueue = {}

local function insertargs(topic, payload, qos, retain)
    table.insert(argsQueue, {t = topic, p = payload, q = qos, r = retain})
end

pmd.ldoset(7, pmd.LDO_VMMC)--使用某些GPIO时，必须在脚本中写代码打开GPIO所属的电压域，配置电压输出输入等级，这些GPIO才能正常工作
local bind --通信板初次使用上电时未绑定，1为绑定
local v_detect
local v_protect
local c_protect1
local c_detect1
local t_sstate1 --闹钟1状态 默认1，未配置0，激活1，不激活2
local t_sstate2 --闹钟1状态 默认1，未配置0，激活1，不激活2
local t_sstate3 --闹钟1状态 默认1，未配置0，激活1，不激活2
local t_sstate4 --闹钟1状态 默认1，未配置0，激活1，不激活2
local t_sstate5 --闹钟1状态 默认1，未配置0，激活1，不激活2
local time1on
local time1off
local time2on
local time2off
local time3on
local time3off
local time4on
local time4off
local time5on
local time5off
local c_min1
local c_max1
local volt --配置控制器电压
local set1 -- 端口1是否配置，
local valid --设备是否过期   0为初始值不过期   1为过期
local switch1

local ledon = false --led是否开启
local led1 = pins.setup(pio.P0_10, 0)--继电器I/O
local led2 = pins.setup(pio.P0_7, 0)--继电器状态灯
local ntpSucceeds = 2 --同步网络时钟初始值，同步完毕为1
local oneminute = 2 --是否开机到1分钟，到1分钟之后才有报警信息
local onnumber = 0 --开机时候开始计数的计数初值，计数到1分钟开始有报警信息
local warning_firstvoltage = 0 --第一次电压警告信息 此时立即发送电压警告  发送之后为1  关机或者连续发送5次警告之后重置为2
local warning_voltage_number1 = 0 --产生电压警告开始计数  每3秒加1
local warning_voltage_number2 = 1 -- number1加到20之后为1  此时计时间隔1分钟 发送电压警告
local warning_voltage_light = 0 --电压异常时电源灯异常闪烁标志 2为正常状态 1为报警状态
local voltage_first_number1 = 0 --电压异常时开始计数标志
local voltage_first_number2 = 0 --电压异常时从0开始计数 连续计时5秒
local voltage_first_number3 = 0 --电流异常时 从0开始计数  连续5秒电流异常
local warning_firstcurrent = 0 --第一次电流警告信息 此时立即发送电流警告  发送之后为1  关机或者连续发送5次警告之后重置为2
local warning_current_number1 = 0 --产生电流警告开始计数  每3秒加1
local warning_current_number2 = 1 -- number1加到60之后计数值加1
local warning_current_light = 0 --电流异常时电源灯异常闪烁标志 2为正常状态 1为报警状态
local current_first_number1 = 0 --电流异常时开始计数标志
local current_first_number2 = 0 --电流异常时从0开始计数 连续计时5秒
local current_first_number3 = 0 --电流异常时 从0开始计数  连续5秒电流异常


function gpio6IntFnc(args)--中断响应按键处理函数
    log.info("testGpioSingle.gpio6IntFnc", args, getGpio6Fnc())
    if args == cpu.INT_GPIO_POSEDGE then --上升沿中断
        if (switch1 == 1) then --如果原来是开机状态，则变为关机状态
            led1(0)
            led2(0)
            switch1 = 0
            nvm.sett("switch1", "switch11", 0)
            nvm.sett("switch1", "switch12", 0)
            poweroffinit()
            torigin =
                {
                    type = "report",
                    cmd = "k_switch",
                    args = {
                        port = 1,
                        switch = 0,
                    }
                }
            insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送按键关机消息
        else --如果原来是关机状态，则变为开机状态
            led1(1)
            led2(1)
            switch1 = 1
            nvm.sett("switch1", "switch11", 1)
            nvm.sett("switch1", "switch12", 1)
            local torigin =
                {
                    type = "report",
                    cmd = "k_switch",
                    args = {
                        port = 1,
                        switch = 1,
                    }
                }
            insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送按键开机消息
        end
    end
end

getGpio6Fnc = pins.setup(6, gpio6IntFnc)--GPIO6配置为中断，可通过getGpio6Fnc()获取输入电平，产生中断时，自动执行gpio6IntFnc函数

local function ntpSucceed()--同步网络时钟
    log.info("testAlarm.ntpSucceed")
    ntpSucceeds = 1
    log.info("ntpsucceeds", ntpSucceeds)
    nvminit()
end

function waitForSend()
    return #argsQueue > 0
end

function mqttReceiveargs(MqttClient)--
    local result, data
    while true do
        result, data = MqttClient:receive(2000)
        if result then
            local tjsondata = json.decode(data.payload)--解析收到的JSon格式的MQTT消息
            if result and type(tjsondata) == "table" then
                log.info("OP=", tjsondata["OP"])
                
                if (tjsondata["type"] == "config") then
                    if (tjsondata["cmd"] == "b_device") then --绑定设备
                        log.info("ZQCTest receive", data.topic, data.payload)
                        log.info("nvm_bindsuccess1")
                        bind = 1 --设备已绑定
                        nvm.sett("bind", "bind1", 1)
                        nvm.sett("bind", "bind2", 1)
                        nvm.sett("v_detect", "v_detect1", 1)
                        nvm.sett("v_detect", "v_detect2", 1)
                        nvm.sett("v_protect", "v_protect1", 0)
                        nvm.sett("v_protect", "v_protect2", 0)
                        nvm.sett("valid", "valid1", 1)
                        nvm.sett("valid", "valid2", 1)
                        nvm.sett("c_detect1", "c_detect11", 0)
                        nvm.sett("c_detect1", "c_detect12", 0)
                        nvm.sett("c_protect1", "c_protect11", 0)
                        nvm.sett("c_protect1", "c_protect12", 0)
                        nvm.sett("t_sstate1", "t_sstate11", 0)
                        nvm.sett("t_sstate1", "t_sstate12", 0)
                        nvm.sett("t_sstate2", "t_sstate21", 0)
                        nvm.sett("t_sstate2", "t_sstate22", 0)
                        nvm.sett("t_sstate3", "t_sstate31", 0)
                        nvm.sett("t_sstate3", "t_sstate32", 0)
                        nvm.sett("t_sstate4", "t_sstate41", 0)
                        nvm.sett("t_sstate4", "t_sstate42", 0)
                        nvm.sett("t_sstate5", "t_sstate51", 0)
                        nvm.sett("t_sstate5", "t_sstate52", 0)
                        nvm.sett("time1on", "time1on1", 100)
                        nvm.sett("time1on", "time1on2", 100)
                        nvm.sett("time1off", "time1off1", 100)
                        nvm.sett("time1off", "time1off2", 100)
                        nvm.sett("time2on", "time2on1", 100)
                        nvm.sett("time2on", "time2on2", 100)
                        nvm.sett("time2off", "time2off1", 100)
                        nvm.sett("time2off", "time2off2", 100)
                        nvm.sett("time3on", "time3on1", 100)
                        nvm.sett("time3on", "time3on2", 100)
                        nvm.sett("time3off", "time3off1", 100)
                        nvm.sett("time3off", "time3off2", 100)
                        nvm.sett("time4on", "time4on1", 100)
                        nvm.sett("time4on", "time4on2", 100)
                        nvm.sett("time4off", "time4off1", 100)
                        nvm.sett("time4off", "time4off2", 100)
                        nvm.sett("time5on", "time5on1", 100)
                        nvm.sett("time5on", "time5on2", 100)
                        nvm.sett("time5off", "time5off1", 100)
                        nvm.sett("time5off", "time5off2", 100)
                        nvm.sett("set1", "set11", 0)
                        nvm.sett("set1", "set12", 0)
                        nvm.sett("c_min1", "c_min11", 0)
                        nvm.sett("c_min1", "c_min12", 0)
                        nvm.sett("c_max1", "c_max11", 0)
                        nvm.sett("c_max1", "c_max12", 0)
                        nvm.sett("switch1", "switch11", 0)
                        nvm.sett("switch1", "switch12", 0)
                        log.info("nvm_bindsuccess")
                        
                        if ((tjsondata["args"]["voltage"] ~= nil) and (tjsondata["args"]["v_detect"] ~= nil) and (tjsondata["args"]["v_protect"] ~= nil)) then
                            v_detect = tjsondata["args"]["v_detect"]
                            nvm.sett("v_detect", "v_detect1", v_detect)
                            nvm.sett("v_detect", "v_detect2", v_detect)
                            v_protect = tjsondata["args"]["v_protect"]
                            nvm.sett("v_protect", "v_protect1", v_protect)
                            nvm.sett("v_protect", "v_protect2", v_protect)
                            voltage = tjsondata["args"]["voltage"]
                            nvm.sett("volt", "volt1", voltage)
                            nvm.sett("volt", "volt2", voltage)
                            log.info("nvmvvoltsuccess")
                            if true then
                                local torigin =
                                    {
                                        type = "config",
                                        cmd = "b_device",
                                        args = {
                                            v_detect = v_detect,
                                            v_protect = v_protect,
                                            voltage = voltage,
                                        },
                                    }
                                insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                            else
                                local torigin =
                                    {
                                        type = "config",
                                        cmd = "b_device",
                                        args = "nvmfail",
                                    }
                                insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                            end
                        end
                    end
                    
                    if (tjsondata["cmd"] == "u_device") then --解绑设备
                        log.info("ZQCTest receive", data.topic, data.payload)
                        bind = 0 --设备已绑定
                        log.info("nvm_unbindsuccess")
                        nvm.sett("bind", "bind1", 0)
                        nvm.sett("bind", "bind2", 0)
                        nvm.sett("v_detect", "v_detect1", 1)
                        nvm.sett("v_detect", "v_detect2", 1)
                        nvm.sett("v_protect", "v_protect1", 0)
                        nvm.sett("v_protect", "v_protect2", 0)
                        nvm.sett("c_detect1", "c_detect11", 0)
                        nvm.sett("c_detect1", "c_detect12", 0)
                        nvm.sett("c_protect1", "c_protect11", 0)
                        nvm.sett("c_protect1", "c_protect12", 0)
                        nvm.sett("t_sstate1", "t_sstate11", 0)
                        nvm.sett("t_sstate1", "t_sstate12", 0)
                        nvm.sett("t_sstate2", "t_sstate21", 0)
                        nvm.sett("t_sstate2", "t_sstate22", 0)
                        nvm.sett("t_sstate3", "t_sstate31", 0)
                        nvm.sett("t_sstate3", "t_sstate32", 0)
                        nvm.sett("t_sstate4", "t_sstate41", 0)
                        nvm.sett("t_sstate4", "t_sstate42", 0)
                        nvm.sett("t_sstate5", "t_sstate51", 0)
                        nvm.sett("t_sstate5", "t_sstate52", 0)
                        nvm.sett("time1on", "time1on1", 100)
                        nvm.sett("time1on", "time1on2", 100)
                        nvm.sett("time1off", "time1off1", 100)
                        nvm.sett("time1off", "time1off2", 100)
                        nvm.sett("time2on", "time2on1", 100)
                        nvm.sett("time2on", "time2on2", 100)
                        nvm.sett("time2off", "time2off1", 100)
                        nvm.sett("time2off", "time2off2", 100)
                        nvm.sett("time3on", "time3on1", 100)
                        nvm.sett("time3on", "time3on2", 100)
                        nvm.sett("time3off", "time3off1", 100)
                        nvm.sett("time3off", "time3off2", 100)
                        nvm.sett("time4on", "time4on1", 100)
                        nvm.sett("time4on", "time4on2", 100)
                        nvm.sett("time4off", "time4off1", 100)
                        nvm.sett("time4off", "time4off2", 100)
                        nvm.sett("time5on", "time5on1", 100)
                        nvm.sett("time5on", "time5on2", 100)
                        nvm.sett("time5off", "time5off1", 100)
                        nvm.sett("time5off", "time5off2", 100)
                        nvm.sett("set1", "set11", 0)
                        nvm.sett("set1", "set12", 0)
                        nvm.sett("volt", "volt1", 220)
                        nvm.sett("volt", "volt2", 220)
                        nvm.sett("c_min1", "c_min11", 0)
                        nvm.sett("c_min1", "c_min12", 0)
                        nvm.sett("c_max1", "c_max11", 0)
                        nvm.sett("c_max1", "c_max12", 0)
                        nvm.sett("switch1", "switch11", 0)
                        nvm.sett("switch1", "switch12", 0)
                        nvm.sett("valid", "valid1", 1)
                        nvm.sett("valid", "valid2", 1)
                        if true then
                            local torigin =
                                {
                                    type = "config",
                                    cmd = "u_device",
                                    args = "",
                                }
                            insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                        else
                            local torigin =
                                {
                                    type = "config",
                                    cmd = "s_devive",
                                    args = "nvmfail",
                                }
                            insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                        end
                    end
                    
                    if (tjsondata["cmd"] == "s_device") then
                        log.info("nvm_s_devivesuccess")
                        if ((tjsondata["args"]["v_detect"] ~= nil) and (tjsondata["args"]["v_protect"] ~= nil)) then
                            v_detect = tjsondata["args"]["v_detect"]
                            v_protect = tjsondata["args"]["v_protect"]
                            log.info("nvm_s_v_detectsuccess")
                            nvm.sett("v_detect", "v_detect1", v_detect)
                            nvm.sett("v_detect", "v_detect2", v_detect)
                            nvm.sett("v_protect", "v_protect1", v_detect)
                            nvm.sett("v_protect", "v_protect2", v_detect)
                            if true then
                                local torigin =
                                    {
                                        type = "config",
                                        cmd = "s_device",
                                        args = {
                                            v_detect = v_detect,
                                            v_protect = v_protect,
                                        },
                                    }
                                insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                            else
                                local torigin =
                                    {
                                        type = "config",
                                        cmd = "s_devive",
                                        args = "nvmfail",
                                    }
                                insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                            end
                        end
                    end
                    
                    if (tjsondata["cmd"] == "s_valid") then --设备是否过期 args为0时，设备过期，需续费之后才能使用 为1时 设备不过期
                        valid = tjsondata["args"]
                        nvm.sett("valid", "valid1", valid)
                        nvm.sett("valid", "valid2", valid)
                        if true then
                            local torigin =
                                {
                                    type = "config",
                                    cmd = "s_valid",
                                    args = "",
                                }
                            insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                        else
                            local torigin =
                                {
                                    type = "config",
                                    cmd = "s_devive",
                                    args = "nvmfail",
                                }
                            insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                        end
                    end
                    
                    if (tjsondata["cmd"] == "s_port") then
                        log.info("nvm_cdetectsuccess2")
                        if (tjsondata["args"]["port"] == 1) then
                            set1 = 1
                            nvm.sett("set1", "set11", set1)
                            nvm.sett("set1", "set12", set1)
                            log.info("set1=", set1)
                            if ((tjsondata["args"]["c_detect"] ~= nil) and (tjsondata["args"]["c_protect"] == nil)) then
                                c_detect1 = tjsondata["args"]["c_detect"]
                                nvm.sett("c_detect1", "c_detect11", c_detect1)
                                nvm.sett("c_detect1", "c_detect12", c_detect1)
                                log.info("nvm_cdetectsuccess")
                                if true then
                                    local torigin =
                                        {
                                            type = "config",
                                            cmd = "s_port",
                                            args = {
                                                port = 1,
                                                c_detect = c_detect1,
                                            },
                                        }
                                    insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                --             end
                                else
                                    local torigin =
                                        {
                                            type = "config",
                                            cmd = "bind",
                                            args = "nvmfail",
                                        }
                                    insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                end
                            end
                            
                            if ((tjsondata["args"]["c_detect"] == nil) and (tjsondata["args"]["c_protect"] ~= nil)) then
                                c_protect1 = tjsondata["args"]["c_protect"]
                                nvm.sett("c_protect1", "c_protect11", c_protect1)
                                nvm.sett("c_protect1", "c_protect12", c_protect1)
                                log.info("nvm_c_protect1success")
                                if true then
                                    local torigin =
                                        {
                                            type = "config",
                                            cmd = "s_port",
                                            args = {
                                                port = 1,
                                                c_protect = c_protect1,
                                            },
                                        }
                                    insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                --             end
                                else
                                    local torigin =
                                        {
                                            type = "config",
                                            cmd = "s_port",
                                            args = "nvmfail",
                                        }
                                    insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                end
                            end
                            
                            if ((tjsondata["args"]["c_detect"] ~= nil) and (tjsondata["args"]["c_protect"] ~= nil)) then
                                c_protect1 = tjsondata["args"]["c_protect"]
                                nvm.sett("c_protect1", "c_protect11", c_protect1)
                                nvm.sett("c_protect1", "c_protect12", c_protect1)
                                c_detect1 = tjsondata["args"]["c_detect"]
                                nvm.sett("c_detect1", "c_detect11", c_detect1)
                                nvm.sett("c_detect1", "c_detect12", c_detect1)
                                c_min1 = tonumber(tjsondata["args"]["c_min"])
                                nvm.sett("c_min1", "c_min11", c_min1)
                                nvm.sett("c_min1", "c_min12", c_min1)
                                c_max1 = tonumber(tjsondata["args"]["c_max"])
                                nvm.sett("c_max1", "c_max11", c_max1)
                                nvm.sett("c_max1", "c_max12", c_max1)
                                
                                log.info("nvm_cprotectc_detect1success")
                                if true then
                                    local torigin =
                                        {
                                            type = "config",
                                            cmd = "s_port",
                                            args = {
                                                port = 1,
                                                c_detect = c_detect1,
                                                c_protect = c_protect1,
                                                c_min = c_min1,
                                                c_max = c_max1,
                                            },
                                        }
                                    insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                --             end
                                else
                                    local torigin =
                                        {
                                            type = "config",
                                            cmd = "s_port",
                                            args = "nvmfail",
                                        }
                                    insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                end
                            end
                        end
                    
                    end
                    
                    if (tjsondata["cmd"] == "u_port") then
                        if ((tjsondata["args"] == 1)) then
                            set1 = 0
                            nvm.sett("c_detect1", "c_detect11", 0)
                            nvm.sett("c_detect1", "c_detect12", 0)
                            nvm.sett("c_protect1", "c_protect11", 0)
                            nvm.sett("c_protect1", "c_protect12", 0)
                            nvm.sett("t_sstate1", "t_sstate11", 0)
                            nvm.sett("t_sstate1", "t_sstate12", 0)
                            nvm.sett("t_sstate2", "t_sstate21", 0)
                            nvm.sett("t_sstate2", "t_sstate22", 0)
                            nvm.sett("t_sstate3", "t_sstate31", 0)
                            nvm.sett("t_sstate3", "t_sstate32", 0)
                            nvm.sett("t_sstate4", "t_sstate41", 0)
                            nvm.sett("t_sstate4", "t_sstate42", 0)
                            nvm.sett("t_sstate5", "t_sstate51", 0)
                            nvm.sett("t_sstate5", "t_sstate52", 0)
                            nvm.sett("time1on", "time1on1", 100)
                            nvm.sett("time1on", "time1on2", 100)
                            nvm.sett("time1off", "time1off1", 100)
                            nvm.sett("time1off", "time1off2", 100)
                            nvm.sett("time2on", "time2on1", 100)
                            nvm.sett("time2on", "time2on2", 100)
                            nvm.sett("time2off", "time2off1", 100)
                            nvm.sett("time2off", "time2off2", 100)
                            nvm.sett("time3on", "time3on1", 100)
                            nvm.sett("time3on", "time3on2", 100)
                            nvm.sett("time3off", "time3off1", 100)
                            nvm.sett("time3off", "time3off2", 100)
                            nvm.sett("time4on", "time4on1", 100)
                            nvm.sett("time4on", "time4on2", 100)
                            nvm.sett("time4off", "time4off1", 100)
                            nvm.sett("time4off", "time4off2", 100)
                            nvm.sett("time5on", "time5on1", 100)
                            nvm.sett("time5on", "time5on2", 100)
                            nvm.sett("time5off", "time5off1", 100)
                            nvm.sett("time5off", "time5off2", 100)
                            nvm.sett("set1", "set11", 0)
                            nvm.sett("set1", "set12", 0)
                            nvm.sett("c_min1", "c_min11", 0)
                            nvm.sett("c_min1", "c_min12", 0)
                            nvm.sett("c_max1", "c_max11", 0)
                            nvm.sett("c_max1", "c_max12", 0)
                            if true then
                                local torigin =
                                    {
                                        type = "config",
                                        cmd = "u_port",
                                        args = 1,
                                    }
                                insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                            else
                                local torigin =
                                    {
                                        type = "config",
                                        cmd = "u_port",
                                        args = "nvmfail",
                                    }
                                insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                            end
                        end
                    end
                    
                    if (tjsondata["cmd"] == "s_timer") then --设置闹钟的开关机时间
                        log.info("this is CLOCKset")
                        if (tjsondata["args"]["port"] == 1) then
                            log.info("this is CLOCKset1")
                            if (tjsondata["args"]["timer"] == 1) then
                                log.info("this is CLOCKset2")
                                if (tjsondata["args"]["t_state"] == 0) then
                                    log.info("this is CLOCKset3")
                                    t_sstate1 = 0
                                    nvm.sett("t_sstate1", "t_sstate11", 0)
                                    nvm.sett("t_sstate1", "t_sstate12", 0)
                                    nvm.sett("time1on", "time1on1", 100)
                                    nvm.sett("time1on", "time1on2", 100)
                                    nvm.sett("time1off", "time1off1", 100)
                                    nvm.sett("time1off", "time1off2", 100)
                                    if true then
                                        local torigin =
                                            {
                                                type = "config",
                                                cmd = "s_timer",
                                                args = {
                                                    timer = 1,
                                                    port = 1,
                                                    t_sstate = 0,
                                                }
                                            }
                                        insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送配置回调
                                    else
                                        local torigin =
                                            {
                                                type = "config",
                                                cmd = "s_timer",
                                                args = "nvmfail",
                                            }
                                        insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                    end
                                elseif (tjsondata["args"]["t_state"] == 1) then
                                    t_sstate1 = 1
                                    nvm.sett("t_sstate1", "t_sstate11", 1)
                                    nvm.sett("t_sstate1", "t_sstate12", 1)
                                    log.info("this is CLOCKset4")
                                    local time = tjsondata["args"]["t_value"]
                                    log.info("t_value", time)
                                    local stime = tonumber(string.sub(time, 1, 4))
                                    if (stime ~= nil) then
                                        local hour1 = math.modf(stime / 60)--计算第一个闹钟开启的小时数
                                        local min1 = math.fmod(stime, 60)--计算第一个闹钟开启的分钟数
                                        log.info("this is CLOCK1-1 on")
                                        local tab = {year = os.date("%Y"), month = os.date("%m"), day = os.date("%d"), hour = hour1, min = min1, sec = 0}
                                        time1on = os.time(tab)--获取设定时间的时间戳
                                        log.info("time1on", time1on)
                                        nvm.sett("time1on", "time1on1", time1on)--写入非易失存储器
                                        nvm.sett("time1on", "time1on2", time1on)
                                        log.info("stime = ", stime)
                                    end
                                    
                                    local etime = tonumber(string.sub(time, 5, 8))
                                    if (etime ~= nil) then
                                        local hour2 = math.modf(etime / 60)
                                        local min2 = math.fmod(etime, 60)
                                        log.info("this is CLOCK1-1 off")
                                        local tab = {year = os.date("%Y"), month = os.date("%m"), day = os.date("%d"), hour = hour2, min = min2, sec = 0}
                                        time1off = os.time(tab)--获取设定时间的时间戳
                                        log.info("time1off", time1off)
                                        nvm.sett("time1off", "time1off1", time1off)--写入非易失存储器
                                        nvm.sett("time1off", "time1off2", time1off)
                                        if true then
                                            local torigin =
                                                {
                                                    type = "config",
                                                    cmd = "s_timer",
                                                    args = {
                                                        timer = 1,
                                                        port = 1,
                                                        t_sstate = 1,
                                                        t_value = time,
                                                    }
                                                }
                                            insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送配置回调
                                        else
                                            local torigin =
                                                {
                                                    type = "config",
                                                    cmd = "s_timer",
                                                    args = "nvmfail",
                                                }
                                            insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                        end
                                    end
                                end
                            end
                            
                            if (tjsondata["args"]["timer"] == 2) then
                                if (tjsondata["args"]["tstate"] == 0) then
                                    t_sstate2 = 0
                                    nvm.sett("t_sstate2", "t_sstate21", 0)
                                    nvm.sett("t_sstate2", "t_sstate22", 0)
                                    nvm.sett("time2on", "time2on1", 100)
                                    nvm.sett("time2on", "time2on2", 100)
                                    nvm.sett("time2off", "time2off1", 100)
                                    nvm.sett("time2off", "time2off2", 100)
                                    if true then
                                        local torigin =
                                            {
                                                type = "config",
                                                cmd = "s_timer",
                                                args = {
                                                    timer = 2,
                                                    port = 1,
                                                    t_sstate = 0,
                                                }
                                            }
                                        insertargs("/device/config/" .. misc.getImei(), json.encode(torigin))--发送配置回调
                                    else
                                        local torigin =
                                            {
                                                type = "config",
                                                cmd = "s_timer",
                                                args = "nvmfail",
                                            }
                                        insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                    end
                                elseif (tjsondata["args"]["t_state"] == 1) then
                                    t_sstate2 = 1
                                    nvm.sett("t_sstate2", "t_sstate21", 1)
                                    nvm.sett("t_sstate2", "t_sstate22", 1)
                                    local time = tjsondata["args"]["t_value"]
                                    local stime = tonumber(string.sub(time, 1, 4))
                                    if (stime ~= nil) then
                                        local hour1 = math.modf(stime / 60)--计算第一个闹钟开启的小时数
                                        local min1 = math.fmod(stime, 60)--计算第一个闹钟开启的分钟数
                                        log.info("this is CLOCK1-2 on")
                                        local tab = {year = os.date("%Y"), month = os.date("%m"), day = os.date("%d"), hour = hour1, min = min1, sec = 0}
                                        time2on = os.time(tab)--获取设定时间的时间戳
                                        log.info("time2on", time2on)
                                        nvm.sett("time2on", "time2on1", time2on)--写入非易失存储器
                                        nvm.sett("time2on", "time2on2", time2on)
                                    end
                                    
                                    local etime = tonumber(string.sub(time, 5, 8))
                                    if (etime ~= 0) then
                                        local hour2 = math.modf(etime / 60)
                                        local min2 = math.fmod(etime, 60)
                                        log.info("this is CLOCK1-2 off")
                                        local tab = {year = os.date("%Y"), month = os.date("%m"), day = os.date("%d"), hour = hour2, min = min2, sec = 0}
                                        time2off = os.time(tab)--获取设定时间的时间戳
                                        log.info("time2off", time2off)
                                        nvm.sett("time2off", "time2off1", time2off)--写入非易失存储器
                                        nvm.sett("time2off", "time2off2", time2off)
                                        if true then
                                            local torigin =
                                                {
                                                    type = "config",
                                                    cmd = "s_timer",
                                                    args = {
                                                        timer = 2,
                                                        port = 1,
                                                        t_sstate = t_sstate1,
                                                        tvalue = time,
                                                    }
                                                }
                                            insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送配置回调
                                        else
                                            local torigin =
                                                {
                                                    type = "config",
                                                    cmd = "s_timer",
                                                    args = "nvmfail",
                                                }
                                            insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                        end
                                    end
                                end
                            end
                            
                            if (tjsondata["args"]["timer"] == 3) then
                                if (tjsondata["args"]["t_state"] == 0) then
                                    t_sstate3 = 0
                                    nvm.sett("t_sstate3", "t_sstate31", 0)
                                    nvm.sett("t_sstate3", "t_sstate32", 0)
                                    nvm.sett("time3on", "time3on1", 100)
                                    nvm.sett("time3on", "time3on2", 100)
                                    nvm.sett("time3off", "time3off1", 100)
                                    nvm.sett("time3off", "time3off2", 100)
                                    if true then
                                        local torigin =
                                            {
                                                type = "config",
                                                cmd = "s_timer",
                                                args = {
                                                    timer = 3,
                                                    port = 1,
                                                    t_sstate = 0,
                                                }
                                            }
                                        insertargs("/device/config/" .. misc.getImei(), json.encode(torigin))--发送配置回调
                                    else
                                        local torigin =
                                            {
                                                type = "config",
                                                cmd = "s_timer",
                                                args = "nvmfail",
                                            }
                                        insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                    end
                                elseif (tjsondata["args"]["t_state"] == 1) then
                                    t_sstate3 = 1
                                    nvm.sett("t_sstate3", "t_sstate31", 1)
                                    nvm.sett("t_sstate3", "t_sstate32", 1)
                                    local time = tjsondata["args"]["t_value"]
                                    local stime = tonumber(string.sub(time, 1, 4))
                                    if (stime ~= nil) then
                                        local hour1 = math.modf(stime / 60)--计算第一个闹钟开启的小时数
                                        local min1 = math.fmod(stime, 60)--计算第一个闹钟开启的分钟数
                                        log.info("this is CLOCK1-3 on")
                                        local tab = {year = os.date("%Y"), month = os.date("%m"), day = os.date("%d"), hour = hour1, min = min1, sec = 0}
                                        time3on = os.time(tab)--获取设定时间的时间戳
                                        log.info("time3on", time3on)
                                        nvm.sett("time3on", "time3on1", time3on)--写入非易失存储器
                                        nvm.sett("time3on", "time3on2", time3on)
                                    end
                                    
                                    local etime = tonumber(string.sub(time, 5, 8))
                                    if (etime ~= 0) then
                                        local hour2 = math.modf(etime / 60)
                                        local min2 = math.fmod(etime, 60)
                                        log.info("this is CLOCK1-3 off")
                                        local tab = {year = os.date("%Y"), month = os.date("%m"), day = os.date("%d"), hour = hour2, min = min2, sec = 0}
                                        time3off = os.time(tab)--获取设定时间的时间戳
                                        log.info("time3off", time3off)
                                        nvm.sett("time3off", "time3off1", time3off)--写入非易失存储器
                                        nvm.sett("time3off", "time3off2", time3off)
                                        if true then
                                            local torigin =
                                                {
                                                    type = "config",
                                                    cmd = "s_timer",
                                                    args = {
                                                        timer = 3,
                                                        port = 1,
                                                        t_sstate = t_sstate3,
                                                        tvalue = time,
                                                    }
                                                }
                                            insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送配置回调
                                        else
                                            local torigin =
                                                {
                                                    type = "config",
                                                    cmd = "s_timer",
                                                    args = "nvmfail",
                                                }
                                            insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                        end
                                    end
                                end
                            end
                            
                            if (tjsondata["args"]["timer"] == 4) then
                                if (tjsondata["args"]["t_state"] == 0) then
                                    t_sstate4 = 0
                                    nvm.sett("t_sstate4", "t_sstate41", 0)
                                    nvm.sett("t_sstate4", "t_sstate42", 0)
                                    nvm.sett("time4on", "time4on1", 100)
                                    nvm.sett("time4on", "time4on2", 100)
                                    nvm.sett("time4off", "time4off1", 100)
                                    nvm.sett("time4off", "time4off2", 100)
                                    if true then
                                        local torigin =
                                            {
                                                type = "config",
                                                cmd = "s_timer",
                                                args = {
                                                    timer = 4,
                                                    port = 1,
                                                    t_sstate = 0,
                                                }
                                            }
                                        insertargs("/device/config/" .. misc.getImei(), json.encode(torigin))--发送配置回调
                                    else
                                        local torigin =
                                            {
                                                type = "config",
                                                cmd = "s_timer",
                                                args = "nvmfail",
                                            }
                                        insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                    end
                                elseif (tjsondata["args"]["t_state"] == 1) then
                                    t_sstate4 = 1
                                    nvm.sett("t_sstate4", "t_sstate41", 1)
                                    nvm.sett("t_sstate4", "t_sstate42", 1)
                                    local time = tjsondata["args"]["t_value"]
                                    local stime = tonumber(string.sub(time, 1, 4))
                                    if (stime ~= nil) then
                                        local hour1 = math.modf(stime / 60)--计算第一个闹钟开启的小时数
                                        local min1 = math.fmod(stime, 60)--计算第一个闹钟开启的分钟数
                                        log.info("this is CLOCK1-4 on")
                                        local tab = {year = os.date("%Y"), month = os.date("%m"), day = os.date("%d"), hour = hour1, min = min1, sec = 0}
                                        time4on = os.time(tab)--获取设定时间的时间戳
                                        log.info("time4on", time4on)
                                        nvm.sett("time4on", "time4on1", time4on)--写入非易失存储器
                                        nvm.sett("time4on", "time4on2", time4on)
                                    end
                                    
                                    local etime = tonumber(string.sub(time, 5, 8))
                                    if (etime ~= 0) then
                                        local hour2 = math.modf(etime / 60)
                                        local min2 = math.fmod(etime, 60)
                                        log.info("this is CLOCK1-4 off")
                                        local tab = {year = os.date("%Y"), month = os.date("%m"), day = os.date("%d"), hour = hour2, min = min2, sec = 0}
                                        time4off = os.time(tab)--获取设定时间的时间戳
                                        log.info("time4off", time4off)
                                        nvm.sett("time4off", "time4off1", time4off)--写入非易失存储器
                                        nvm.sett("time4off", "time4off2", time4off)
                                        if true then
                                            local torigin =
                                                {
                                                    type = "config",
                                                    cmd = "s_timer",
                                                    args = {
                                                        timer = 4,
                                                        port = 1,
                                                        t_sstate = t_sstate4,
                                                        tvalue = time,
                                                    }
                                                }
                                            insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送配置回调
                                        else
                                            local torigin =
                                                {
                                                    type = "config",
                                                    cmd = "s_timer",
                                                    args = "nvmfail",
                                                }
                                            insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                        end
                                    end
                                end
                            end
                            
                            if (tjsondata["args"]["timer"] == 5) then
                                if (tjsondata["args"]["t_state"] == 0) then
                                    t_sstate5 = 0
                                    nvm.sett("t_sstate5", "t_sstate51", 0)
                                    nvm.sett("t_sstate5", "t_sstate52", 0)
                                    nvm.sett("time5on", "time5on1", 100)
                                    nvm.sett("time5on", "time5on2", 100)
                                    nvm.sett("time5off", "time5off1", 100)
                                    nvm.sett("time5off", "time5off2", 100)
                                    if true then
                                        local torigin =
                                            {
                                                type = "config",
                                                cmd = "s_timer",
                                                args = {
                                                    timer = 5,
                                                    port = 1,
                                                    t_sstate = 0,
                                                }
                                            }
                                        insertargs("/device/config/" .. misc.getImei(), json.encode(torigin))--发送配置回调
                                    else
                                        local torigin =
                                            {
                                                type = "config",
                                                cmd = "s_timer",
                                                args = "nvmfail",
                                            }
                                        insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                    end
                                elseif (tjsondata["args"]["t_state"] == 1) then
                                    t_sstate5 = 1
                                    nvm.sett("t_sstate5", "t_sstate51", 1)
                                    nvm.sett("t_sstate5", "t_sstate52", 1)
                                    local time = tjsondata["args"]["t_value"]
                                    local stime = tonumber(string.sub(time, 1, 4))
                                    if (stime ~= nil) then
                                        local hour1 = math.modf(stime / 60)--计算第一个闹钟开启的小时数
                                        local min1 = math.fmod(stime, 60)--计算第一个闹钟开启的分钟数
                                        log.info("this is CLOCK1-5 on")
                                        local tab = {year = os.date("%Y"), month = os.date("%m"), day = os.date("%d"), hour = hour1, min = min1, sec = 0}
                                        time5on = os.time(tab)--获取设定时间的时间戳
                                        log.info("time5on", time5on)
                                        nvm.sett("time5on", "time5on1", time5on)--写入非易失存储器
                                        nvm.sett("time5on", "time5on2", time5on)
                                    end
                                    
                                    local etime = tonumber(string.sub(time, 5, 8))
                                    if (etime ~= 0) then
                                        local hour2 = math.modf(etime / 60)
                                        local min2 = math.fmod(etime, 60)
                                        log.info("this is CLOCK1-5 off")
                                        local tab = {year = os.date("%Y"), month = os.date("%m"), day = os.date("%d"), hour = hour2, min = min2, sec = 0}
                                        time5off = os.time(tab)--获取设定时间的时间戳
                                        log.info("time5off", time5off)
                                        nvm.sett("time5off", "time5off1", time5off)--写入非易失存储器
                                        nvm.sett("time5off", "time5off2", time5off)
                                        if true then
                                            local torigin =
                                                {
                                                    type = "config",
                                                    cmd = "s_timer",
                                                    args = {
                                                        timer = 5,
                                                        port = 1,
                                                        t_sstate = t_sstate1,
                                                        tvalue = time,
                                                    }
                                                }
                                            insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送配置回调
                                        else
                                            local torigin =
                                                {
                                                    type = "config",
                                                    cmd = "s_timer",
                                                    args = "nvmfail",
                                                }
                                            insertargs("/warn/state/" .. misc.getImei(), json.encode(torigin))--发送绑定成功消息
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                
                if (tjsondata["type"] == "control") then --远程开机
                    log.info("ZQCTest receive", data.topic, data.payload)
                    if (tjsondata["cmd"] == "on") then
                        log.info("port12223")
                        local val = tjsondata["args"]
                        local a = #val
                        local b = 1
                        for i = 1, a do
                            if (val[i] == b) then
                                if (set1 == 1) then
                                    log.info("port1on")
                                    led1(1)
                                    led2(1)
                                    switch1 = 1 --开机状态
                                    nvm.sett("switch1", "switch11", 1)
                                    nvm.sett("switch1", "switch12", 1)
                                    if true then
                                        local torigin =
                                            {
                                                type = "control",
                                                cmd = "on",
                                                args = tjsondata["args"],
                                            }
                                        insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送已开机消息
                                    end
                                end
                            end
                        end
                    end
                    
                    if (tjsondata["cmd"] == "off") then
                        local val = tjsondata["args"]
                        local a = #val
                        local b = 1
                        log.info("ZQCTest receive", data.topic, data.payload)
                        for i = 0, a do
                            if val[i] == 1 then
                                if (set1 == 1) then
                                    led1(0)
                                    led2(0)
                                    switch1 = 0 --开机状态
                                    nvm.sett("switch1", "switch11", 1)
                                    nvm.sett("switch1", "switch12", 1)
                                    if true then
                                        local torigin =
                                            {
                                                type = "control",
                                                cmd = "off",
                                                args = tjsondata["args"],
                                            }
                                        insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送已关机消息
                                    end
                                end
                                poweroffinit()
                            end
                        end
                    end
                end
                
                if (tjsondata["type"] == "read") then --查询电流电压信号强度
                    
                    if (tjsondata["cmd"] == "current") then
                        local csq = net.getRssi()--信号强度
                        log.info("csq = ", csq)
                        local state_a = uart8032.IRMS --电流强度强度，格式为 0.1A
                        log.info("state_a = ", state_a)
                        state_a = tostring(state_a)
                        local a = tonumber(string.format('%0.2f', state_a))
                        local switch1 = tostring(switch1)
                        local torigin =
                            {
                                type = "read",
                                cmd = "current",
                                args = {
                                    
                                    csq = csq,
                                    port1 = a,
                                    port_switch = switch1,
                                    time = os.date()
                                }
                            }
                        insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送电流值
                    end
                    
                    if (tjsondata["cmd"] == "status") then
                        local csq = net.getRssi()--信号强度
                        log.info("csq = ", csq)
                        local torigin =
                            {
                                type = "read",
                                cmd = "status",
                                args = {
                                    csq = csq,
                                    port_set = set1,
                                    port_switch = switch1,
                                }
                            }
                        insertargs("/device/state/" .. misc.getImei(), json.encode(torigin))--发送电流值
                    end
                end
            
            end
        else
            break;
        end
    end
    return result or data == "timeout"
end

function mqttPublishargs(MqttClient)
    while #argsQueue > 0 do
        local outargs = table.remove(argsQueue, 1)
        local result = MqttClient:publish(outargs.t, outargs.p, outargs.q, outargs.r)
        if not result then
            return
        end
    end
    return true
end

sys.taskInit(
    function()
        while true do
            local retryConnectCnt = 0
            if socket.isReady() then
                local imei = misc.getImei()
                local torigin1 =
                    {
                        type = "report",
                        cmd = "offline",
                        args = 0,
                    }
                local MqttClient = mqtt.client(imei, 60, mqttuser, mqttpassword, nil, {qos = 0, retain = 1, topic = "/device/warn/" .. misc.getImei(), payload = json.encode(torigin1)})--遗嘱为{"args":"offLine"}
                if MqttClient:connect(MqttIp, MqttPort, "tcp") then
                    log.info("ZQCTest", "connect success")
                    local state_v = uart8032.VRMS --		--连接mqtt服务器成功即发送进线电压和上线成功消息，格式为{"args":"onLine","inVolt":"380"}
                    log.info("state_v = ", state_v)
                    if ((state_v > 187) and (state_v < 253)) then
                        state_v = 220
                        volt = 220
                        nvm.sett("volt", "volt1", 220)
                        nvm.sett("volt", "volt2", 220)
                    elseif ((state_v > 323) and (state_v < 437)) then
                        state_v = 380
                        volt = 380
                        nvm.sett("volt", "volt1", 380)
                        nvm.sett("volt", "volt2", 380)
                    else
                        state_v = tonumber(string.format('%d', state_v))
                        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin), 0, 1)--
                    end
                    local torigin =
                        {
                            csq = net.getRssi(),
                            type = "report",
                            cmd = "online",
                            args = state_v,
                        }
                    insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin), 0, 1)--
                    retryConnectCnt = 0
                    if MqttClient:subscribe({["/server/action/" .. imei] = 0}, {["/serve/valid/" .. imei] = 0}) then
                        while true do
                            if not mqttReceiveargs(MqttClient) then
                                log.error("MqttLuatClient.mqttReceiveargs error")
                                break
                            end
                            if not mqttPublishargs(MqttClient) then
                                log.error("MqttLuatClient.mqttPublishargs error")
                                break
                            end
                        end
                    end
                else
                    log.info("mqttTest.mqttClient", "connect fail")
                    retryConnectCnt = retryConnectCnt + 1
                end
                MqttClient:disconnect()
                if retryConnectCnt >= 5 then
                    link.shut()
                    retryConnectCnt = 0
                end
                sys.wait(5000)
            else
                sys.waitUntil("IP_READY_IND", 300000)
                if not socket.isReady() then
                    net.switchFly(true)
                    sys.wait(20000)
                    net.switchFly(false)
                end
            end
        end
    end
)
local function ledtwinkle()
    if switch1 == 1 then
        if ((warning_voltage_light == 1) or (warning_current_light == 1)) then --产生警告时电源灯闪烁
            log.info("lighttwinkle")
            if ledon then
                led2(1)
            else
                led2(0)
            end
            ledon = not ledon
        else led2(1)
        end
    end
end

local function timeChk()--循环执行
    if (switch1 == 1) and (oneminute == 2) then --开机之后60秒计时，60秒之后才发布警告信息
        log.info("onnumber = ", onnumber)
        onnumber = onnumber + 1
        if (onnumber > 20) then --
            onnumber = 0
            oneminute = 1
            log.info("warning on")
        end
    end
    
    if ntpSucceeds == 1 then --同步系统时间之后
        log.info("os.time", os.time(), "set1", set1, "t_sstate1", t_sstate1, "c_detect1", c_detect1, "switch1", switch1)
        if ((set1 == 1) and (valid == 1)) then --端口1已经配置并且不过期时
            
            if (time1on ~= 100) then --如果第一个时间点写入了新的时间，表示已经设置闹钟
                if ((t_sstate1 == 1) and (os.time() > time1on) and (os.time() < (time1on + 3))) then --到了设定的时间戳
                    log.info("time1 is start")
                    led1(1)
                    led2(1)
                    switch1 = 1 --开机状态
                    nvm.sett("switch1", "switch11", 1)
                    nvm.sett("switch1", "switch12", 1)
                    time1on = time1on + 24 * 60 * 60
                    nvm.set("time1on", time1on)--新的时间戳加一整天的秒数
                    log.info("time1onnew = ", time1on)
                end
            end
            
            if (time1off ~= 100) then
                if ((t_sstate1 == 1) and (os.time() > time1off) and (os.time() < (time1off + 3))) then
                    log.info("time1 is over")
                    led1(0)
                    led2(0)
                    switch1 = 0 --开机状态
                    nvm.sett("switch1", "switch11", 0)
                    nvm.sett("switch1", "switch12", 0)
                    poweroffinit()
                    time1off = time1off + 24 * 60 * 60
                    nvm.set("time1off", time1off)
                    log.info("time1offnew = ", time1off)
                end
            end
            
            if (time2on ~= 100) then
                if ((t_sstate2 == 1) and (os.time() > time2on) and (os.time() < (time2on + 3))) then
                    log.info("time2 is start")
                    led1(1)
                    led2(1)
                    switch1 = 1 --开机状态
                    nvm.sett("switch1", "switch11", 1)
                    nvm.sett("switch1", "switch12", 1)
                    time2on = time2on + 24 * 60 * 60
                    nvm.set("time2on", time2on)
                    log.info("time2onnew = ", time2on)
                end
            end
            
            if (time2off ~= 100) then
                if ((t_sstate2 == 1) and (os.time()) > time2off and (os.time() < (time2off + 3))) then
                    log.info("time2 is over")
                    led1(0)
                    led2(0)
                    switch1 = 0 --开机状态
                    nvm.sett("switch1", "switch11", 0)
                    nvm.sett("switch1", "switch12", 0)
                    poweroffinit()
                    time2off = time2off + 24 * 60 * 60
                    nvm.set("time2off", time2off)
                    log.info("time2offnew = ", time2off)
                end
            end
            
            if (time3on ~= 100) then
                if ((t_sstate3 == 1) and (os.time()) > time3on and (os.time() < (time3on + 3))) then
                    log.info("time3 is start")
                    led1(1)
                    led2(1)
                    switch1 = 1 --开机状态
                    nvm.sett("switch1", "switch11", 1)
                    nvm.sett("switch1", "switch12", 1)
                    time3on = time3on + 24 * 60 * 60
                    nvm.set("time3on", time3on)
                    log.info("time3onnew = ", time3on)
                end
            end
            
            if (time3off ~= 100) then
                if ((t_sstate3 == 1) and (os.time()) > time3off and (os.time() < (time3off + 3))) then
                    log.info("time3 is over")
                    led1(0)
                    led2(0)
                    switch1 = 0 --开机状态
                    nvm.sett("switch1", "switch11", 0)
                    nvm.sett("switch1", "switch12", 0)
                    poweroffinit()
                    time3off = time3off + 24 * 60 * 60
                    nvm.set("time2off", time3off)
                    log.info("time2offnew = ", time3off)
                end
            end
            
            if (time4on ~= 100) then
                if ((t_sstate4 == 1) and (os.time()) > time4on and (os.time() < (time4on + 3))) then
                    log.info("time4 is start")
                    led1(1)
                    led2(1)
                    switch1 = 1 --开机状态
                    nvm.sett("switch1", "switch11", 1)
                    nvm.sett("switch1", "switch12", 1)
                    time4on = time4on + 24 * 60 * 60
                    nvm.set("time4on", time4on)
                    log.info("time4onnew = ", time4on)
                end
            end
            
            if (time4off ~= 100) then
                if ((t_sstate4 == 1) and (os.time()) > time4off and (os.time() < (time4off + 3))) then
                    log.info("time4 is over")
                    led1(0)
                    led2(0)
                    switch1 = 0 --开机状态
                    nvm.sett("switch1", "switch11", 0)
                    nvm.sett("switch1", "switch12", 0)
                    poweroffinit()
                    time4off = time4off + 24 * 60 * 60
                    nvm.set("time4off", time4off)
                    log.info("time4offnew = ", time4off)
                end
            end
            
            if (time5on ~= 100) then
                if ((t_sstate5 == 1) and (os.time()) > time5on and (os.time() < (time5on + 3))) then
                    log.info("time5 is start")
                    led1(1)
                    led2(1)
                    switch1 = 1 --开机状态
                    nvm.sett("switch1", "switch11", 1)
                    nvm.sett("switch1", "switch12", 1)
                    time5on = time5on + 24 * 60 * 60
                    nvm.set("time5on", time5on)
                    log.info("time5onnew = ", time5on)
                end
            end
            
            if (time5off ~= 100) then
                if ((t_sstate5 == 1) and (os.time()) > time5off and (os.time() < (time5off + 3))) then
                    log.info("time5 is over")
                    led1(0)
                    led2(0)
                    switch1 = 0 --开机状态
                    nvm.sett("switch1", "switch11", 0)
                    nvm.sett("switch1", "switch12", 0)
                    poweroffinit()
                    time5off = time5off + 24 * 60 * 60
                    nvm.set("time5off", time5off)
                    log.info("time5offnew = ", time5off)
                end
            end
        end
    end
end

local function warning()
    
    local state_v = uart8032.VRMS --实时电压值
    local state_a = uart8032.IRMS
    if ((switch1 == 1) and (oneminute == 1) and (set1 == 1) and (valid == 1)) then --开机，开机1分钟之后，端口1已经配置，没有到期的情况下才有警告信息
        if (v_detect == 1) then
            if (volt == 220) then
                if ((state_v > 253) or (state_v < 187)) then --实时电压超过设置电压的20%，过压
                    warningvoltage = 1
                else warning_voltage_light = 0
                    led2(1)
                end
            elseif (volt == 380) then
                if ((state_v > 437) or (state_v < 323)) then
                    warningvoltage = 1
                else warning_voltage_light = 0
                    led2(1)
                end
            end
        end
        
        if (warningvoltage == 1) then --设置电压报警
            --    log.info("warningvoltage = ", warningvoltage)
            if (warning_firstvoltage == 1) then
                warning_voltage_number1 = warning_voltage_number1 + 1
                log.info("warning_voltage_number1 = ", warning_voltage_number1)
                log.info("warning_voltage_number2 = ", warning_voltage_number2)
                if (warning_voltage_number1 > 59) then
                    warning_voltage_number1 = 0
                    warning_voltage_number2 = warning_voltage_number2 + 1
                    
                    if (warning_voltage_number2 <= 5) then
                        log.info("warning:voltagereport")
                        local torigin =
                            {
                                type = "report",
                                cmd = "v_warn",
                                args =
                                {
                                    phase = 1,
                                    v_outlier = tonumber(string.format('%d', state_v)),
                                    time = os.date()
                                }
                            }
                        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--发送过压警告
                        warning_voltage_light = 1 --警告灯闪烁
                    else
                        warning_firstvoltage = 2
                        warning_voltage_number1 = 2
                        warning_voltage_number2 = 1
                        voltage_first_number1 = 0
                        voltage_first_number2 = 0
                        voltage_first_number3 = 0
                    end
                end
            end
            
            if (warning_firstvoltage == 0) then --初次电压异常时连续计时5秒
                log.info("warning:warning_firstvoltage", warning_firstvoltage)
                voltage_first_number1 = 1
                voltage_first_number3 = voltage_first_number3 + 1
                log.info("warning:voltage_first_number3", voltage_first_number3)
                log.info("warning:voltage_first_number1", voltage_first_number1)
            end
        end
        
        if (voltage_first_number1 == 1) then --连续5秒电压异常发送警报
            voltage_first_number2 = voltage_first_number2 + 1
            log.info("warning:voltage_first_number2", voltage_first_number2)
            if (voltage_first_number2 == 5) then
                if (voltage_first_number3 > 4) then
                    warning_voltage_light = 1
                    warning_firstvoltage = 1
                    log.info("warning:firstvoltage", warning_firstvoltage)
                    local torigin =
                        {
                            type = "report",
                            cmd = "v_warn",
                            args =
                            {
                                phase = 1,
                                v_outlier = tonumber(string.format('%d', state_v)),
                                time = os.date()
                            }
                        }
                    insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))
                    voltage_first_number1 = 0
                end
            end
        end
        
        if (c_detect1 == 1) then --设置电流报警
            if ((state_a > c_max1) or (state_a < c_min1)) then --实时电流不符合设置电流的阈值
                if (warning_firstcurrent == 1) then
                    warning_current_number1 = warning_current_number1 + 1
                    log.info("warning_current_number1 = ", warning_current_number1)
                    log.info("warning_current_number2 = ", warning_current_number2)
                    if (warning_current_number1 > 59) then
                        warning_current_number1 = 0
                        warning_current_number2 = warning_current_number2 + 1
                        
                        if (warning_current_number2 <= 5) then
                            log.info("warning:currentreport")
                            local torigin =
                                {
                                    type = "report",
                                    cmd = "c_warn",
                                    args =
                                    {
                                        port = 1,
                                        c_outlier = tonumber(string.format('%0.2f', state_a)),
                                        time = os.date()
                                    }
                                }
                            insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--发送过压警告
                            warning_current_light = 1 --警告灯闪烁
                        else
                            warning_firstcurrent = 2
                            warning_current_number1 = 2
                            warning_current_number2 = 1
                            current_first_number1 = 0
                            current_first_number2 = 0
                            current_first_number3 = 0
                        end
                    end
                end
                
                if (warning_firstcurrent == 0) then --初次电流异常时连续计时5秒
                    log.info("warning:warning_firstcurrent", warning_firstcurrent)
                    current_first_number1 = 1
                    current_first_number3 = current_first_number3 + 1
                    log.info("warning:current_first_number3", current_first_number3)
                    log.info("warning:current_first_number1", current_first_number1)
                end
            else warning_current_light = 0
                led2(1)
            end
            
            if (current_first_number1 == 1) then --连续5秒电流异常发送警报
                current_first_number2 = current_first_number2 + 1
                log.info("warning:current_first_number2", current_first_number2)
                if (current_first_number2 == 5) then
                    if (current_first_number3 > 4) then
                        warning_current_light = 1
                        warning_firstcurrent = 1
                        log.info("warning:firstcurrent", warning_firstcurrent)
                        local torigin =
                            {
                                type = "report",
                                cmd = "c_warn",
                                args =
                                {
                                    port = 1,
                                    c_outlier = tonumber(string.format('%0.2f', state_a)),
                                    time = os.date()
                                }
                            }
                        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))
                        current_first_number1 = 0
                    end
                end
            end
        end
    end
end

function nvminit()
    local bind1 = nvm.gett("bind", "bind1")
    local bind2 = nvm.gett("bind", "bind2")
    if (bind1 == bind2) then
        bind = bind1
        log.info("bind success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local v_detect1 = nvm.gett("v_detect", "v_detect1")
    local v_detect2 = nvm.gett("v_detect", "v_detect2")
    if (v_detect1 == v_detect2) then
        v_detect = v_detect1
        log.info("v_detect success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local v_protect1 = nvm.gett("v_protect", "v_protect1")
    local v_protect2 = nvm.gett("v_protect", "v_protect2")
    if (v_protect1 == v_protect2) then
        v_protect = v_protect1
        log.info("v_protect success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local c_detect11 = nvm.gett("c_detect1", "c_detect11")
    local c_detect12 = nvm.gett("c_detect1", "c_detect12")
    if (c_detect11 == c_detect12) then
        c_detect1 = c_detect11
        log.info("c_detect1 success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local c_protect11 = nvm.gett("c_protect1", "c_protect11")
    local c_protect12 = nvm.gett("c_protect1", "c_protect12")
    if (c_protect11 == c_protect12) then
        c_protect1 = c_protect11
        log.info("c_protect1 success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local t_sstate11 = nvm.gett("t_sstate1", "t_sstate11")
    local t_sstate12 = nvm.gett("t_sstate1", "t_sstate12")
    if (t_sstate11 == t_sstate12) then
        t_sstate1 = t_sstate11
        log.info("t_sstate1 success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local t_sstate21 = nvm.gett("t_sstate2", "t_sstate21")
    local t_sstate22 = nvm.gett("t_sstate2", "t_sstate22")
    if (t_sstate21 == t_sstate22) then
        t_sstate2 = t_sstate21
        log.info("t_sstate2 success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local t_sstate31 = nvm.gett("t_sstate3", "t_sstate31")
    local t_sstate32 = nvm.gett("t_sstate3", "t_sstate32")
    if (t_sstate31 == t_sstate32) then
        t_sstate31 = t_sstate32
        log.info("t_sstate3 success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local t_sstate41 = nvm.gett("t_sstate4", "t_sstate41")
    local t_sstate42 = nvm.gett("t_sstate4", "t_sstate42")
    if (t_sstate41 == t_sstate42) then
        t_sstate4 = t_sstate41
        log.info("t_sstate4 success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local t_sstate51 = nvm.gett("t_sstate5", "t_sstate51")
    local t_sstate52 = nvm.gett("t_sstate5", "t_sstate52")
    if (t_sstate51 == t_sstate52) then
        t_sstate5 = t_sstate51
        log.info("t_sstate5 success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local time1on1 = nvm.gett("time1on", "time1on1")
    local time1on2 = nvm.gett("time1on", "time1on2")
    if (time1on1 == time1on2) then
        time1on = time1on1
        log.info("time1on success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local time1off1 = nvm.gett("time1off", "time1off1")
    local time1off2 = nvm.gett("time1off", "time1off2")
    if (time1off1 == time1off2) then
        time1off = time1off1
        log.info("time1off success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local time2on1 = nvm.gett("time2on", "time2on1")
    local time2on2 = nvm.gett("time2on", "time2on2")
    if (time2on1 == time2on2) then
        time2on = time2on1
        log.info("time2on success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local time2off1 = nvm.gett("time2off", "time2off1")
    local time2off2 = nvm.gett("time2off", "time2off2")
    if (time2off1 == time2off2) then
        time2off = time2off1
        log.info("time2off success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local time3on1 = nvm.gett("time3on", "time3on1")
    local time3on2 = nvm.gett("time3on", "time3on2")
    if (time3on1 == time3on2) then
        time3on = time3on1
        log.info("time3on success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local time3off1 = nvm.gett("time3off", "time3off1")
    local time3off2 = nvm.gett("time3off", "time3off2")
    if (time3off1 == time3off2) then
        time3off = time3off1
        log.info("time3off success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local time4on1 = nvm.gett("time4on", "time4on1")
    local time4on2 = nvm.gett("time4on", "time4on2")
    if (time4on1 == time4on2) then
        time4on = time4on1
        log.info("time4off success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local time4off1 = nvm.gett("time4off", "time4off1")
    local time4off2 = nvm.gett("time4off", "time4off2")
    if (time4off1 == time4off2) then
        time4off = time4off1
        log.info("time4off success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local time5on1 = nvm.gett("time5on", "time5on1")
    local time5on2 = nvm.gett("time5on", "time5on2")
    if (time5on1 == time5on2) then
        time5on = time5on1
        log.info("time5on success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local time5off1 = nvm.gett("time5off", "time5off1")
    local time5off2 = nvm.gett("time5off", "time5off2")
    if (time5off1 == time5off2) then
        time5off = time5off1
        log.info("time5off success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local set11 = nvm.gett("set1", "set11")
    local set12 = nvm.gett("set1", "set12")
    if (set11 == set12) then
        set1 = set11
        log.info("set1 success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local set21 = nvm.gett("set2", "set21")
    local set22 = nvm.gett("set2", "set22")
    if (set21 == set22) then
        set2 = set21
        log.info("set2 success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end

    local volt1 = nvm.gett("volt", "volt1")
    local volt2 = nvm.gett("volt", "volt2")
    if (volt1 == volt2) then
        volt = volt1
        log.info("volt success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local c_min11 = nvm.gett("c_min1", "c_min11")
    local c_min12 = nvm.gett("c_min1", "c_min12")
    if (c_min11 == c_min12) then
        c_min1 = c_min11
        log.info("c_min1 success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local c_max11 = nvm.gett("c_max1", "c_max11")
    local c_max12 = nvm.gett("c_max1", "c_max12")
    if (c_max11 == c_max12) then
        c_max1 = c_max11
        log.info("c_max1 success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local c_min21 = nvm.gett("c_min2", "c_min21")
    local c_min22 = nvm.gett("c_min2", "c_min22")
    if (c_min21 == c_min22) then
        c_min2 = c_min21
        log.info("c_min2 success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    
    local c_max21 = nvm.gett("c_max2", "c_max21")
    local c_max22 = nvm.gett("c_max2", "c_max22")
    if (c_max21 == c_max22) then
        c_max2 = c_max21
        log.info("c_max2 success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end

    local switch11 = nvm.gett("switch1", "switch11")
    local switch12 = nvm.gett("switch1", "switch12")
    if (switch11 == switch12) then
        switch1 = switch11
        log.info("switch1 success", switch1)
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    if (switch1 == 1) then
        log.info("switch1status", switch1)
        local torigin =
            {
                type = "report",
                cmd = "m_stop",
                args = "[1]",
                time = os.date(),
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
        switch1 = 0
        nvm.sett("switch1", "switch11", 0)
        nvm.sett("switch1", "switch12", 0)
    end
    
    local switch21 = nvm.gett("switch2", "switch21")
    local switch22 = nvm.gett("switch2", "switch22")
    if (switch21 == switch22) then
        switch2 = switch21
        log.info("switch2 success", switch2)
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
    if (switch2 == 1) then
        log.info("switch2status", switch2)
        local torigin =
            {
                type = "report",
                cmd = "m_stop",
                args = "[2]",
                time = os.date(),
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
        switch2 = 0
        nvm.sett("switch2", "switch12", 0)
        nvm.sett("switch2", "switch12", 0)
    end

    local valid1 = nvm.gett("valid", "valid1")
    local valid2 = nvm.gett("valid", "valid2")
    if (valid1 == valid2) then
        valid = valid1
        log.info("valid success")
    else
        local torigin =
            {
                type = "report",
                cmd = "initfail",
                args = "",
            }
        insertargs("/device/warn/" .. misc.getImei(), json.encode(torigin))--
    end
end

function poweroffinit()
    oneminute = 2
    warning_firstvoltage = 0 --关机时参数重置
    warning_voltage_light = 0
    warning_current_light = 0
    warning_voltage_number1 = 0
    warning_voltage_number2 = 1
    voltage_first_number1 = 0
    voltage_first_number2 = 0
    voltage_first_number3 = 0
    warning_firstcurrent = 0
    warning_current_number1 = 0
    warning_current_number2 = 1
    current_first_number1 = 0
    current_first_number2 = 0
    current_first_number3 = 0
end
--启动网络服务器同步时间功能，同步成功后执行ntpSucceed函数，每小时同步一次
ntp.timeSync(1, ntpSucceed)

sys.timerLoopStart(ledtwinkle, 500)
sys.timerLoopStart(timeChk, 1000)
sys.timerLoopStart(warning, 1000)--测试时定时器为1秒  此时每一分钟报警一次
