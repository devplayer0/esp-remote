function starts_with(str, start)
	return string.sub(str, 1, string.len(start)) == start
end

-- a very hacky streaming HTTPS -> JSON decoder
-- based on https://github.com/nodemcu/nodemcu-firmware/blob/master/lua_examples/sjson-streaming.lua
-- this is needed since the built-in http module puts the whole response in memory, and responses
-- from the Spotify API don't fit in the ESP8266's ~48K of RAM!
--
-- A streaming JSON parser (sjson) is used and can be configured to ignore storing values to conserve
-- memory - this is required for calls to Spotify that return a lot of data)
function streaming_request(method, host, path, headers, mt, cb)
	local sock = tls.createConnection()
	sock:on("connection", function(sock, d)
		if method == "POST" or method == "PUT" then
			headers = headers .. "Content-Length: 0\r\n"
		end

		--print("sending streaming request")
		local req = method.." "..path.." HTTP/1.1\r\nUser-Agent: NodeMCU/0.1\r\n"..headers.."Host: "..host.."\r\nConnection: close\r\nAccept: application/json\r\n\r\n\r\n"
		sock:send(req)
	end)

	local decoder = sjson.decoder({
		metatable = mt
	})

	local partial
	local headers_ended = false
	local res_code = nil
	sock:on("receive", function(sock, data)
		--print("received data", node.heap())
		-- we need to deal with the response headers
		if partial then
			data = partial .. data
			partial = nil
		end
		if headers_ended then
			decoder:write(data)
			return
		end

		while data do
			if starts_with(data, "\r\n") then
				-- a blank line means we've reached the end of the headers
				headers_ended = true
				data = data:sub(3)
				decoder:write(data)
				return
			end

			local s, e = data:find("\r\n")
			if s then
				if res_code == nil then
					-- the first "header" is the response status, lets extract and parse the number
					res_code = tonumber(data:sub(10, 12))
					if res_code == 204 then
						-- don't bother feeding the decoder, we won't be getting any JSON
						sock:close()
						return
					end
				end
				data = data:sub(e + 1)
			else
				partial = data
				data = nil
			end
		end
	end)

	local function local_cb()
		--print('final cb')
		-- use a pcall since the decoder will throw an error if there isn't a complete valid json
		local success, data = pcall(function() return decoder:result() end)
		if not success then
			data = nil
		end

		cb(res_code, data)
	end
	sock:on("disconnection", local_cb)
	sock:on("reconnection", local_cb)

	--print("connecting", node.heap())
	sock:connect(443, host)
end
