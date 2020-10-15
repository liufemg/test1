module(...)

bind = {bind1=0,bind2=0}    --控制器是否绑定，默认0，有效1，无效0
v_detect = {v_detect1=1,v_detect2=1}   --电压检测 ，默认1，有效1 ，无效0
v_protect = {v_protect1=0,v_protect2=0}   --电压停机保护，默认0，有效1，无效0
c_detect1 = {c_detect11=1,c_detect12=1}   --端口1电流检测，默认1，有效1 ，无效0
c_protect1 = {c_protect11=0,c_protect12=0}  --电流停机保护，默认0，有效1，无效0
t_sstate1 = {t_sstate11=0,t_sstate12=0}    --闹钟1状态 默认1，未配置0，激活1，不激活2
t_sstate2 = {t_sstate21=0,t_sstate22=0} 
t_sstate3 = {t_sstate31=0,t_sstate32=0} 
t_sstate4 = {t_sstate41=0,t_sstate42=0} 
t_sstate5 = {t_sstate51=0,t_sstate52=0} 
time1on = {time1on1=100,time1on2=100}   --闹钟1未设置开机时间的初始值
time1off = {time1off1=100,time1off2=100}
time2on = {time2on1=100,time2on2=100}
time2off = {time2off1=100,time2off2=100}
time3on = {time3on1=100,time3on2=100}
time3off = {time3off1=100,time3off2=100}
time4on = {time4on1=100,time4on2=100}
time4off = {time4off1=100,time4off2=100}
time5on = {time5on1=100,time5on2=100}
time5off = {time5off1=100,time5off2=100}
set1 = {set11=0,set12=0}       --端口1是否配置，初始值0为未配置，1为配置 
volt = {volt1=220,volt2=220}     --绑定设备的电压值，初始值设置为220V
c_min1 = {c_min11=4,c_min12=4}     --端口1最小警告电流  单位为A 默认值为4 
c_max1 = {c_max11=7,c_max12=7}     --端口1最大警告电流  单位为A 默认值为7
switch1 = {switch11=0,switch12=0}    --通信板初次上电时候端口1电机状态为关机，1为开机
valid = {valid1=1,valid2=1}   --设备是否过期 过期为0 初始值为1 不过期
