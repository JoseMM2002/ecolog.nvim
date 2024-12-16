---@class TypeDefinition
---@field pattern string Lua pattern for matching
---@field validate? fun(value: string): boolean Function for additional validation
---@field transform? fun(value: string): string Function to transform the value

---@class TypesConfig
---@field types boolean|table<string, boolean|TypeDefinition> Type configuration
---@field custom_types? table<string, TypeDefinition> Custom type definitions

local M = {}

-- Built-in type definitions with their patterns and validation functions
local TYPE_DEFINITIONS = {
  -- Data types
  boolean = {
    pattern = "(true|false|yes|no|1|0)",
    validate = function(value)
      local lower = value:lower()
      return lower == "true" or lower == "false" or 
             lower == "yes" or lower == "no" or 
             lower == "1" or lower == "0"
    end,
    transform = function(value)
      local lower = value:lower()
      if lower == "yes" or lower == "1" or lower == "true" then
        return "true"
      end
      return "false"
    end,
  },
  number = {
    pattern = "^-?%d+%.?%d*$",
  },
  json = {
    pattern = "^[%s]*[{%[].-[}%]][%s]*$",
    validate = function(str)
      local status = pcall(function()
        vim.json.decode(str)
      end)
      return status
    end,
  },
  -- Network types
  url = {
    pattern = "^https?://[%w%-%.]+%.[%w%-%.]+[%w%-%./:?=&]*$",
  },
  localhost = {
    pattern = "^https?://(localhost|127%.0%.0%.1)(:%d+)?[%w%-%./:]*$",
  },
  database_url = {
    pattern = "^([%w+]+)://([^:/@]+:[^@]*@)?([^/:]+)(:%d+)?(/[^?]*)?(%?.*)?$",
    validate = function(url)
      local protocol = url:match("^([%w+]+)://")
      if not protocol then return false end
      
      local valid_protocols = {
        ["postgresql"] = true,
        ["postgres"] = true,
        ["mysql"] = true,
        ["mongodb"] = true,
        ["mongodb+srv"] = true,
        ["redis"] = true,
        ["rediss"] = true,
        ["sqlite"] = true,
        ["mariadb"] = true,
        ["cockroachdb"] = true,
      }
      
      return valid_protocols[protocol:lower()] or false
    end
  },
  ipv4 = {
    pattern = "^(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)$",
    validate = function(value)
      local parts = { value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
      if #parts ~= 4 then return false end
      for _, part in ipairs(parts) do
        local num = tonumber(part)
        if not num or num < 0 or num > 255 then return false end
      end
      return true
    end,
  },
  -- Date and time
  iso_date = {
    pattern = "^(%d%d%d%d)-(%d%d)-(%d%d)$",
    validate = function(value)
      local year, month, day = value:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
      year, month, day = tonumber(year), tonumber(month), tonumber(day)
      if not (year and month and day) then
        return false
      end
      if month < 1 or month > 12 then
        return false
      end
      if day < 1 or day > 31 then
        return false
      end
      if (month == 4 or month == 6 or month == 9 or month == 11) and day > 30 then
        return false
      end
      if month == 2 then
        local is_leap = (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
        if (is_leap and day > 29) or (not is_leap and day > 28) then
          return false
        end
      end
      return true
    end,
  },
  iso_time = {
    pattern = "^(%d%d):(%d%d):(%d%d)$",
    validate = function(value)
      local hour, minute, second = value:match("^(%d%d):(%d%d):(%d%d)$")
      hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
      if not (hour and minute and second) then
        return false
      end
      return hour >= 0 and hour < 24 and minute >= 0 and minute < 60 and second >= 0 and second < 60
    end,
  },
  -- Visual
  hex_color = {
    pattern = "^#([%x][%x][%x]|[%x][%x][%x][%x][%x][%x])$",
    validate = function(value)
      local hex = value:sub(2)
      if #hex == 3 then
        hex = hex:gsub(".", function(c)
          return c .. c
        end)
      end
      return #hex == 6 and hex:match("^%x+$") ~= nil
    end,
  },
}

-- Configuration state
local config = {
  enabled_types = {},
  custom_types = {},
}

-- Initialize enabled types with all TYPE_DEFINITIONS enabled
local function init_enabled_types()
  for type_name, _ in pairs(TYPE_DEFINITIONS) do
    config.enabled_types[type_name] = true
  end
end

-- Initialize configuration with defaults
init_enabled_types()

-- Setup function for types module
function M.setup(opts)
  opts = opts or {}

  -- Reset to defaults first
  init_enabled_types()
  config.custom_types = {}

  -- Handle types configuration
  if type(opts.types) == "table" then
    -- Reset all types to false first
    for type_name, _ in pairs(TYPE_DEFINITIONS) do
      config.enabled_types[type_name] = false
    end
    -- Enable only specified types
    for type_name, enabled in pairs(opts.types) do
      if TYPE_DEFINITIONS[type_name] then
        config.enabled_types[type_name] = enabled
      end
    end
  elseif type(opts.types) == "boolean" then
    -- Enable/disable all types based on boolean value
    for type_name, _ in pairs(TYPE_DEFINITIONS) do
      config.enabled_types[type_name] = opts.types
    end
  end

  -- Handle custom types
  if opts.custom_types then
    for name, def in pairs(opts.custom_types) do
      if type(def) == "table" and def.pattern then
        config.custom_types[name] = {
          pattern = def.pattern,
          validate = def.validate,
          transform = def.transform,
        }
      end
    end
  end
end

-- Helper function to check key-value pair
local function check_key_value_pair(value)
  local key, val = value:match("^([%w_]+)=(.+)$")
  if not key then
    return nil
  end

  -- Check if the value part is a boolean
  if config.enabled_types.boolean then
    local lower = val:lower()
    if lower == "true" or lower == "yes" or lower == "1" then
      return "boolean", "true"
    elseif lower == "false" or lower == "no" or lower == "0" then
      return "boolean", "false"
    end
  end
  return nil
end

-- Type detection function
function M.detect_type(value)
  -- First check if it's a key-value pair
  local key_value_type = check_key_value_pair(value)
  if key_value_type then
    return key_value_type
  end

  -- Trim whitespace from value
  value = value:match("^%s*(.-)%s*$") or value

  -- Check built-in types in specific order
  local type_check_order = {
    "boolean",
    "database_url",
    "localhost",
    "url",
    "number",
    "json",
    "ipv4",
    "iso_date",
    "iso_time",
    "hex_color",
  }

  for _, type_name in ipairs(type_check_order) do
    local type_def = TYPE_DEFINITIONS[type_name]
    if type_def and config.enabled_types[type_name] then
      -- For boolean type, do a direct match
      if type_name == "boolean" then
        local lower = value:lower()
        if lower == "true" or lower == "false" or 
           lower == "yes" or lower == "no" or 
           lower == "1" or lower == "0" then
          if type_def.transform then
            value = type_def.transform(value)
          end
          return type_name, value
        end
      else
        -- For other types, use pattern matching
        local matched = value:match(type_def.pattern)
        if matched then
          -- Check validation if exists
          if type_def.validate then
            local is_valid = type_def.validate(value)
            if not is_valid then
              goto continue
            end
          end
          
          -- Transform if needed
          if type_def.transform then
            value = type_def.transform(value)
          end
          
          return type_name, value
        end
      end
      
      ::continue::
    end
  end

  -- Check custom types
  for type_name, type_def in pairs(config.custom_types) do
    if value:match(type_def.pattern) then
      if not type_def.validate or type_def.validate(value) then
        if type_def.transform then
          value = type_def.transform(value)
        end
        return type_name, value
      end
    end
  end

  -- Default to string type
  return "string", value
end

return M
