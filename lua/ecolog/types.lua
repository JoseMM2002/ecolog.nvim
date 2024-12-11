local M = {}

-- Configuration state
local config = {
	custom_types_enabled = true,
	built_in_types_enabled = true,
	basic_types_only = false,  -- New flag for basic types mode
}

-- Setup function for types module
function M.setup(opts)
	opts = opts or {}
	-- Handle types being completely disabled
	if opts.types == false then
		config.custom_types_enabled = false
		config.built_in_types_enabled = false
		config.basic_types_only = true  -- Enable basic types mode
	else
		-- Otherwise enable all types by default
		config.custom_types_enabled = true
		config.built_in_types_enabled = true
		config.basic_types_only = false
		-- Register any custom types if provided
		M.register_custom_types(opts.custom_types)
	end
end

-- Pre-compile patterns for better performance
M.PATTERNS = {
	-- Core types
	number = "^-?%d+%.?%d*$",  -- Integers and decimals
	boolean = "^(true|false|yes|no|1|0)$",
	-- Network types
	ipv4 = "^(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)$",
	url = "^https?://[%w%-%.]+%.[%w%-%.]+[%w%-%./:]*$",  -- Simplified URL pattern for common cases
	localhost = "^https?://(localhost|127%.0%.0%.1)(:%d+)?[%w%-%./:]*$",  -- Localhost URLs
	-- Database URLs
	database_url = "^([%w+]+)://([^:/@]+:[^@]*@)?([^/:]+)(:%d+)?(/[^?]*)?(%?.*)?$",
	-- Date and time
	iso_date = "^(%d%d%d%d)-(%d%d)-(%d%d)$",
	iso_time = "^(%d%d):(%d%d):(%d%d)$",
	-- Data formats
	json = "^[%s]*[{%[].-[}%]][%s]*$",
	-- Color formats
	hex_color = "^#([%x][%x][%x]|[%x][%x][%x][%x][%x][%x])$",  -- #RGB or #RRGGBB
}

-- Known database protocols
local DB_PROTOCOLS = {
	["postgresql"] = true,
	["postgres"] = true,
	["mysql"] = true,
	["mongodb"] = true,
	["mongodb+srv"] = true,
	["redis"] = true,
	["rediss"] = true,  -- Redis with SSL
	["sqlite"] = true,
	["mariadb"] = true,
	["cockroachdb"] = true,
}

-- Store custom types
M.custom_types = {}

-- Validation functions
local function is_valid_ipv4(matches)
	for i = 1, 4 do
		local num = tonumber(matches[i])
		if not num or num < 0 or num > 255 then
			return false
		end
	end
	return true
end

local function is_valid_url(url)
	-- Extract URL components
	local scheme, authority, path, query, fragment = url:match(M.PATTERNS.url)
	if not scheme or not authority then return false end
	
	-- Validate scheme
	local valid_schemes = {
		["http"] = true,
		["https"] = true,
		["ftp"] = true,
		["sftp"] = true,
		["ws"] = true,
		["wss"] = true,
		["git"] = true,
		["ssh"] = true,
		["file"] = true,
	}
	
	if not valid_schemes[scheme:lower()] then return false end
	
	-- Validate authority (host[:port])
	local host, port = authority:match("^([^:]+)(:%d+)?$")
	if not host then return false end
	
	-- Check for valid hostname patterns
	local is_valid_hostname = host:match("^[%w%-%.]+$") and
		not host:match("^%.") and     -- doesn't start with dot
		not host:match("%.$") and     -- doesn't end with dot
		not host:match("%.%.") and    -- no consecutive dots
		host:find("%.") ~= nil        -- has at least one dot
	
	local is_valid_ip = host:match("^%d+%.%d+%.%d+%.%d+$") and
		is_valid_ipv4({host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")})
	
	if not (is_valid_hostname or is_valid_ip) then return false end
	
	-- Validate port if present
	if port then
		local port_num = tonumber(port:sub(2))
		if not port_num or port_num < 1 or port_num > 65535 then
			return false
		end
	end
	
	-- Path validation (if present)
	if path and path ~= "" then
		-- Path should only contain valid characters
		if path:match("[^%w%-_%./%~]") then
			return false
		end
	end
	
	-- Query validation (if present)
	if query then
		-- Query should start with ? and contain valid characters
		if not query:match("^%?[%w%-_%.%~=&%%]*$") then
			return false
		end
	end
	
	-- Fragment validation (if present)
	if fragment then
		-- Fragment should start with # and contain valid characters
		if not fragment:match("^#[%w%-_%.%~%%]*$") then
			return false
		end
	end
	
	return true
end

local function is_valid_localhost(url)
	-- Basic URL validation
	if not url:match("^https?://") then return false end
	
	-- Extract host and optional port
	local host, port = url:match("^https?://([^/:]+)(:%d+)?")
	if not host then return false end
	
	-- Validate localhost variants
	if host ~= "localhost" and host ~= "127.0.0.1" then return false end
	
	-- Validate port if present
	if port then
		local port_num = tonumber(port:sub(2))  -- Remove the colon
		if not port_num or port_num < 1 or port_num > 65535 then
			return false
		end
	end
	
	return true
end

local function is_valid_database_url(url)
	-- Extract URL components
	local protocol, auth, host, port, path, query = url:match(M.PATTERNS.database_url)
	if not protocol or not host then return false end
	
	-- Validate protocol
	if not DB_PROTOCOLS[protocol:lower()] then return false end
	
	-- Validate port if present
	if port then
		local port_num = tonumber(port:sub(2))  -- Remove the colon
		if not port_num or port_num < 1 or port_num > 65535 then
			return false
		end
	end
	
	-- Special validation for sqlite
	if protocol:lower() == "sqlite" then
		-- SQLite requires a path
		if not path or path == "/" then return false end
		return true
	end
	
	-- Special validation for mongodb+srv
	if protocol:lower() == "mongodb+srv" then
		-- mongodb+srv requires a hostname and doesn't use ports
		if port then return false end
		-- Must have at least one dot in hostname (DNS requirement)
		if not host:find("%.") then return false end
	end
	
	return true
end

local function is_valid_json(str)
	local status = pcall(function() vim.json.decode(str) end)
	return status
end

local function is_valid_hex_color(hex)
	-- Remove the # prefix
	hex = hex:sub(2)
	-- Convert 3-digit hex to 6-digit
	if #hex == 3 then
		hex = hex:gsub(".", function(c) return c..c end)
	end
	-- Check if all characters are valid hex digits
	return #hex == 6 and hex:match("^%x+$") ~= nil
end

local function is_valid_date(year, month, day)
	year, month, day = tonumber(year), tonumber(month), tonumber(day)
	if not (year and month and day) then return false end
	
	if month < 1 or month > 12 then return false end
	if day < 1 or day > 31 then return false end
	
	-- Check months with 30 days
	if (month == 4 or month == 6 or month == 9 or month == 11) and day > 30 then
		return false
	end
	
	-- Check February
	if month == 2 then
		local is_leap = (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
		if (is_leap and day > 29) or (not is_leap and day > 28) then
			return false
		end
	end
	
	return true
end

local function is_valid_time(hour, minute, second)
	hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
	if not (hour and minute and second) then return false end
	
	return hour >= 0 and hour < 24 and
		minute >= 0 and minute < 60 and
		second >= 0 and second < 60
end

-- Type detection function
function M.detect_type(value)
	-- Basic types mode - only string and number
	if config.basic_types_only then
		-- Check for number first
		if value:match(M.PATTERNS.number) then
			return "number", value
		end
		-- Default to string
		return "string", value
	end

	-- Full type detection mode
	if config.built_in_types_enabled then
		if value:match(M.PATTERNS.url) then
			return "url", value
		elseif value:match(M.PATTERNS.localhost) and is_valid_localhost(value) then
			return "localhost", value
		elseif value:match(M.PATTERNS.database_url) and is_valid_database_url(value) then
			return "database_url", value
		end
	end

	-- Check custom types only if enabled
	if config.custom_types_enabled then
		for type_name, type_def in pairs(M.custom_types) do
			if value:match(type_def.pattern) then
				if not type_def.validate or type_def.validate(value) then
					if type_def.transform then
						value = type_def.transform(value)
					end
					return type_name, value
				end
			end
		end
	end
	
	-- Check other built-in types if enabled
	if config.built_in_types_enabled then
		if value:match(M.PATTERNS.boolean) then
			-- Normalize boolean values
			value = value:lower()
			if value == "yes" or value == "1" or value == "true" then
				value = "true"
			else
				value = "false"
			end
			return "boolean", value
		elseif value:match(M.PATTERNS.json) and is_valid_json(value) then
			return "json", value
		elseif value:match(M.PATTERNS.hex_color) and is_valid_hex_color(value) then
			return "hex_color", value
		elseif value:match(M.PATTERNS.database_url) and is_valid_database_url(value) then
			return "database_url", value
		elseif value:match(M.PATTERNS.localhost) and is_valid_localhost(value) then
			return "localhost", value
		elseif value:match(M.PATTERNS.url) and is_valid_url(value) then
			return "url", value
		else
			-- Check IPv4 with validation
			local ip_parts = {value:match(M.PATTERNS.ipv4)}
			if #ip_parts == 4 and is_valid_ipv4(ip_parts) then
				return "ipv4", value
			-- Check date with validation
			elseif value:match(M.PATTERNS.iso_date) then
				local year, month, day = value:match(M.PATTERNS.iso_date)
				if is_valid_date(year, month, day) then
					return "iso_date", value
				end
			-- Check time with validation
			elseif value:match(M.PATTERNS.iso_time) then
				local hour, minute, second = value:match(M.PATTERNS.iso_time)
				if is_valid_time(hour, minute, second) then
					return "iso_time", value
				end
			-- Check number last (after more specific numeric types)
			elseif value:match(M.PATTERNS.number) then
				return "number", value
			end
		end
	else
		-- When built-in types are disabled but not in basic mode,
		-- still check for number type
		if value:match(M.PATTERNS.number) then
			return "number", value
		end
	end
	
	-- Default to string type
	return "string", value
end

-- Register custom types
function M.register_custom_types(types)
	M.custom_types = {}  -- Clear existing custom types
	for type_name, type_def in pairs(types or {}) do
		if type(type_def) == "table" and type_def.pattern then
			M.custom_types[type_name] = {
				pattern = type_def.pattern,
				validate = type_def.validate,
				transform = type_def.transform
			}
		else
			vim.notify(string.format(
				"Invalid custom type definition for '%s': must be a table with at least a 'pattern' field",
				type_name
			), vim.log.levels.WARN)
		end
	end
end

return M 