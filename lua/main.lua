function init_disp(sda, scl, sla)
	-- initialize i2c
	i2c.setup(0, sda, scl, i2c.SLOW)
	-- initialize the 128x32 OLED display
	local disp = u8g2.ssd1306_i2c_128x32_univision(0, sla)
	return disp
end

function connect_wifi(disp, sta_conf, cb)
	-- show the SSID we're connecting to on the screen
	disp:setFont(u8g2.font_6x10_tf)
	disp:drawStr(0, 9, "Connecting...")
	disp:drawStr(0, 19, sta_conf.ssid)
	disp:sendBuffer()

	-- station or "client" mode
	wifi.setmode(wifi.STATION)
	-- set the SSID and password and kick off connection
	wifi.sta.config(sta_conf)
	local timeout = tmr.create()
	timeout:alarm(30000, tmr.ALARM_SINGLE, function()
			-- if we haven't got an IP from DHCP after 30 seconds, give up and reboot
			disp:clearBuffer()
			disp:drawStr(0, 9, "Timed out connecting")
			disp:sendBuffer()

			if not tmr.create():alarm(3000, tmr.ALARM_SINGLE, node.restart)
			then
				node.restart()
			end
	end)

	-- register a listener for successful connection (before getting an IP)
	wifi.eventmon.register(wifi.eventmon.STA_CONNECTED, function(info)
		wifi.eventmon.unregister(wifi.eventmon.STA_CONNECTED)

		disp:clearBuffer()
		disp:drawStr(0, 9, "Connected, waiting")
		disp:drawStr(0, 19, "for IP address")
		disp:sendBuffer()

		wifi.eventmon.register(wifi.eventmon.STA_GOT_IP, function(info)
			-- we're all connected up now, so the timeout can be cancelled
			timeout:unregister()
			wifi.eventmon.unregister(wifi.eventmon.STA_GOT_IP)
			-- if we ever lose connection, reboot
			wifi.eventmon.register(wifi.eventmon.STA_DISCONNECTED, function(info)
				disp:setFont(u8g2.font_6x10_tf)
				disp:clearBuffer()
				disp:drawStr(0, 9, "Lost connection")
				disp:drawStr(0, 19, "Rebooting...")
				disp:sendBuffer()

				if not tmr.create():alarm(3000, tmr.ALARM_SINGLE, node.restart)
				then
					node.restart()
				end
			end)

			disp:clearBuffer()
			disp:drawStr(0, 9, "Got IP:")
			disp:drawStr(0, 19, info.IP)
			disp:sendBuffer()
			cb()
		end)
	end)
end

-- the display is connected to SDA on D2 (GPIO4) and SCL on D1 (GPIO5)
-- the i2c address is 0x3c
local disp = init_disp(2, 1, 0x3c)

-- load config with the SSID, password and Spotify backend token
local succeeded, config = pcall(function() return dofile("config.lua") end)
if not succeeded then
	disp:setFont(u8g2.font_6x10_tf)
	disp:clearBuffer()
	disp:drawStr(0, 9, "Failed to load")
	disp:drawStr(0, 19, "config.lua, please")
	disp:drawStr(0, 29, "upload it to SPIFFS")
	disp:sendBuffer()
	return
end

connect_wifi(disp, config.wifi, function()
	dofile("spotify.lua")(disp, config)
end)
