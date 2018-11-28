require "streaming_rest"

local display_width = 128
local font_width = 6
function truncate_str(s)
	local width = string.len(s)*font_width
	if width < display_width*2 then
		return s, width
	end

	-- if the string is more than twice the width of the display, 
	-- the text will wrap around and overlap what's already on the display
	width = math.floor((display_width*2)/font_width)
	return s:sub(1, width), display_width*2
end

function die(line1, line2, line3)
	disp:setFont(u8g2.font_6x10_tf)
	disp:clearBuffer()
	disp:drawStr(0, 9, line1)
	if line2 then
		disp:drawStr(0, 19, line2)
	end
	if line3 then
		disp:drawStr(0, 29, line3)
	end
	disp:sendBuffer()

	tmr.delay(3000000)
	node.restart()
end

function refresh_token(cb)
	-- get a Spotify token from the backend (usually valid for an hour)
	http.get("http://espremote.cf/spotify_token?token=" .. config.remote_token, "", function(code, data)
		print("refreshing token")
		if code ~= 200 then
			die("Failed to refresh", "Spotify token")
		end
		token = data
		cb()
	end)
end

function spotify_call(mt, method, endpoint, cb)
	if not token then
		refresh_token(function()
			spotify_call(mt, method, endpoint, cb)
		end)
		return
	end

	streaming_request(method, "api.spotify.com", endpoint, "Authorization: Bearer "..token.."\r\n", mt, function(code, data)
		if code == 401 then
			-- 401 means an expired token, let's get a new one
			refresh_token(function()
				spotify_call(mt, method, endpoint, cb)
			end)
			return
		end
		
		cb(code, data)
	end)
end

function draw_scrolled(line, y)
	disp:drawUTF8(line.x, y, line.text)

	if line.x + line.width <= display_width then
		if line.t_end == 7 then
			-- reset the scroll to the start
			line.x = 0
			line.t_end = 0
		else
			-- hold the end of the scroll for a bit
			line.t_end = line.t_end + 1
		end
	else
		line.x = line.x - 2
	end
end
function draw_xbm(x, y, xbm)
	disp:drawXBM(x, y, xbm.width, xbm.height, xbm.data)
end

playing = 0
device = ""
track = {
	text = "",
	width = 0,
	x = 0,
	t_end = 0
}
artist = {
	text = "",
	width = 0,
	x = 0,
	t_end = 0
}

queue_toggle = false
function toggle_playing(cb)
	local endpoint = nil
	if playing == 0 then
		cb()
		return
	elseif playing == 1 then
		-- send a play or pause based on the current locally cached state
		endpoint = "/v1/me/player/pause"
	else
		endpoint = "/v1/me/player/play"
	end

	spotify_call(nil, "PUT", endpoint, function(code, json)
		if code ~= 204 then
			if json and json["error"] then
				die("Spotify API error", json["message"])
			else
				die("Spotify API error")
			end
		end

		if playing == 1 then
			playing = 2
		else
			playing = 1
		end

		cb()
	end)

end
function refresh_info(cb)
	if queue_toggle then
		-- a play / pause was requested, lets do that instead of
		-- updating from Spotify
		toggle_playing(function() 
			queue_toggle = false
			cb()
		end)
		return
	end

	-- because the ESP8266 is so memory-contrained, we need to tell the streaming JSON parser
	-- to only keep values in keys we care about
	local keys = { error = 1, message=1, device=1, item=1, artists=1, is_playing=1, name=1 }
	spotify_call({
		__newindex = function(t, k, v)
			if keys[k] or type(k) == "number" then
				rawset(t, k, v)
			end
		end
	}, "GET", "/v1/me/player", function(code, json)
		if code == 204 then
			-- if we get a 204 No Content there are no active sessions (playing or paused)
			playing = 0
			device = ""
			track.text = ""
			track.width = 0
			artist.text, artist.width = truncate_str("No active sessions")

			cb()
			return
		end

		if code ~= 200 or not json or json["error"] then
			local message = ""
			if json then
				message = json["message"]
			end
			die("Spotify API error", message)
			return
		end

		if json.is_playing then
			playing = 1
		else
			playing = 2
		end

		device = truncate_str(json.device.name)

		t_old = track.text
		track.text, track.width = truncate_str(json.item.name)
		if track.text ~= t_old then
			track.t_end = 0
			track.x = 0
		end

		art = ""
		for i, a in ipairs(json.item.artists) do
			-- Spotify gives an array of artists, lets concatenate them
			art = art .. a.name
			if i ~= table.getn(json.item.artists) then
				art = art .. ', '
			end
		end

		artist.text, artist.width = truncate_str(art)
		if art ~= artist.text then
			artist.t_end = 0
			artist.x = 0
		end

		cb()
	end)
end

-- MONO image data - saved initially as XBM files from GIMP, converted with `convert` to .mono and
-- then translated to a Lua `string.char()` statement with the `img/bin2lua.py` script
local play_symbol = {
	data = string.char(0x0, 0x0, 0x18, 0x0, 0x38, 0x0, 0x78, 0x0, 0xf8, 0x0, 0xf8, 0x0, 0x78, 0x0, 0x38, 0x0, 0x18, 0x0, 0x0, 0x0),
	width = 10,
	height = 10
}
local pause_symbol = {
	data = string.char(0x0, 0x0, 0xcc, 0x0, 0xcc, 0x0, 0xcc, 0x0, 0xcc, 0x0, 0xcc, 0x0, 0xcc, 0x0, 0xcc, 0x0, 0xcc, 0x0, 0x0, 0x0),
	width = 10,
	height = 10
}
function button_click(level, when, ev_count, cb)
	queue_toggle = true
end
return function(d, c)
	disp = d
	config = c

	-- try and squeeze a bit more performance out of the ESP8266
	node.setcpufreq(node.CPU160MHZ)

	track.text, track.width = truncate_str("Loading data from Spotify API")
	-- display update loop
	tmr.create():alarm(200, tmr.ALARM_AUTO, function()
		disp:setFont(u8g2.font_6x10_tf)
		disp:clearBuffer()

		if playing == 1 then
			draw_xbm(0, 0, play_symbol)
		elseif playing == 2 then
			draw_xbm(0, 0, pause_symbol)
		end
		disp:drawUTF8(12, 9, device)
		draw_scrolled(track, 19)
		draw_scrolled(artist, 29)

		disp:sendBuffer()
	end)

	-- refresh the data from Spotify 1 second after each request completes
	local info_timer = tmr.create()
	info_timer:alarm(1000, tmr.ALARM_SEMI, function()
		refresh_info(function() info_timer:start() end)
	end)

	-- D3 (GPIO0) is wired to the PRG / FLASH button, lets set up an interrupt
	-- to pause / play the music
	gpio.mode(3, gpio.INT)
	gpio.trig(3, "up", button_click)
end
