local M = {}
local api = vim.api
local fn = vim.fn
local notify = vim.notify
local providers = require("ecolog.providers")
local select = require("ecolog.select")
local peek = require("ecolog.peek")

-- Cache and state management
local env_vars = {}
local cached_env_files = nil
local last_opts = nil

-- Find environment files
local function find_env_files(opts)
	opts = opts or {}
	opts.path = opts.path or fn.getcwd()
	opts.preferred_environment = opts.preferred_environment or ""

	-- Use cached files if possible
	if
		cached_env_files
		and last_opts
		and last_opts.path == opts.path
		and last_opts.preferred_environment == opts.preferred_environment
	then
		return cached_env_files
	end

	-- Store options for cache validation
	last_opts = vim.tbl_extend("force", {}, opts)

	-- Find all env files
	local raw_files = fn.globpath(opts.path, ".env*", false, true)
	local files = vim.tbl_filter(function(v)
		-- Match either .env or .env.something
		return v:match("%.env$") or v:match("%.env%.[^.]+$")
	end, raw_files)

	-- If no files found, return empty list
	if #files == 0 then
		return {}
	end

	-- Sort files by priority
	table.sort(files, function(a, b)
		-- If preferred environment is specified, prioritize it
		if opts.preferred_environment ~= "" then
			local a_is_preferred = b:match("%.env%." .. opts.preferred_environment .. "$") ~= nil
			local b_is_preferred = a:match("%.env%." .. opts.preferred_environment .. "$") ~= nil
			if a_is_preferred ~= b_is_preferred then
				return a_is_preferred
			end
		end

		-- Then prioritize .env file
		local a_is_env = b:match("%.env$") ~= nil
		local b_is_env = a:match("%.env$") ~= nil
		print(a_is_env, b_is_env, a, b, a_is_env ~= b_is_env)
		if a_is_env ~= b_is_env then
			return a_is_env
		end

		-- Default to alphabetical order
		return a < b
	end)

	cached_env_files = files
	return files
end

-- Parse environment files
local function parse_env_file(opts, force)
	if not force and next(env_vars) ~= nil then
		return
	end

	local env_files = find_env_files(opts)

	env_vars = {}

	for _, file_path in ipairs(env_files) do
		local env_file = io.open(file_path, "r")
		if env_file then
			for line in env_file:lines() do
				if line:match("^[^#]") and line:match("^.+$") then
					local key, value = line:match("([^=]+)=(.+)")
					if key and value then
						value = value:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
						key = key:gsub("^%s*(.-)%s*$", "%1")
						env_vars[key] = {
							value = value,
							type = tonumber(value) and "number" or "string",
							source = file_path,
						}
					end
				end
			end
			env_file:close()
		end
	end
end

-- Environment variable type checking
function M.check_env_type(var_name, opts)
	parse_env_file(opts)

	local var = env_vars[var_name]
	if var then
		notify(
			string.format(
				"Environment variable '%s' exists with type: %s (from %s)",
				var_name,
				var.type,
				fn.fnamemodify(var.source, ":t")
			),
			vim.log.levels.INFO
		)
		return var.type
	else
		notify(string.format("Environment variable '%s' does not exist", var_name), vim.log.levels.WARN)
		return nil
	end
end

-- Refresh environment variables
function M.refresh_env_vars(opts)
	cached_env_files = nil
	last_opts = nil
	parse_env_file(opts, true)
	notify("Environment variables refreshed", vim.log.levels.INFO)
end

-- Setup function
function M.setup(opts)
	opts = opts or {}
	-- Set default value for hide_cmp_values
	opts.hide_cmp_values = opts.hide_cmp_values ~= false

	-- Create highlight groups
	require("ecolog.highlights").setup()
	parse_env_file(opts)

	-- Register built-in providers first
	local typescript = require("ecolog.providers.typescript")
	local javascript = require("ecolog.providers.javascript")
	local python = require("ecolog.providers.python")
	local php = require("ecolog.providers.php")

	-- Register each provider directly since we know their structure
	providers.register_many(typescript)
	providers.register_many(javascript)
	if type(python) == "table" and python.provider then
		providers.register(python.provider)
	else
		providers.register(python)
	end
	providers.register_many(php)

	-- Register completion source
	local has_cmp, cmp = pcall(require, "cmp")
	if has_cmp then
		-- Create highlight groups for cmp
		vim.api.nvim_set_hl(0, "CmpItemKindEcolog", { link = "EcologVariable" })
		vim.api.nvim_set_hl(0, "CmpItemAbbrMatchEcolog", { link = "EcologVariable" })
		vim.api.nvim_set_hl(0, "CmpItemAbbrMatchFuzzyEcolog", { link = "EcologVariable" })
		vim.api.nvim_set_hl(0, "CmpItemMenuEcolog", { link = "EcologSource" })

		cmp.register_source("ecolog", {
			get_trigger_characters = function()
				return { ".", "'" }  -- Add '.' for process.env and import.meta.env
			end,

			complete = function(self, request, callback)
				local filetype = vim.bo.filetype
				local available_providers = providers.get_providers(filetype)
				
				-- Check if we're typing after any of the provider patterns
				local should_complete = false
				local line = request.context.cursor_before_line
				
				for _, provider in ipairs(available_providers) do
					local trigger = provider.get_completion_trigger()
					-- Create a pattern that matches partial completion of the trigger
					local parts = vim.split(trigger, ".", { plain = true })
					local partial_pattern = ""
					for i, part in ipairs(parts) do
						if i > 1 then
							partial_pattern = partial_pattern .. "%."
						end
						partial_pattern = partial_pattern .. vim.pesc(part)
						if line:match(partial_pattern .. "$") then
							should_complete = true
							break
						end
					end
					
					if should_complete then
						break
					end
				end
				
				if not should_complete then
					callback({ items = {}, isIncomplete = false })
					return
				end
				
				parse_env_file()

				local items = {}
				for var_name, var_info in pairs(env_vars) do
					local doc_value = opts.hide_cmp_values and string.rep("*", #var_info.value) or var_info.value
					local doc = string.format("**Type:** `%s`", var_info.type)

					if not opts.hide_cmp_values then
						doc = doc .. string.format("\n**Value:** `%s`", doc_value)
					end

					table.insert(items, {
						label = var_name,
						kind = cmp.lsp.CompletionItemKind.Variable,
						detail = fn.fnamemodify(var_info.source, ":t"),
						documentation = {
							kind = "markdown",
							value = doc,
						},
						kind_hl_group = "CmpItemKindEcolog",
						menu_hl_group = "CmpItemMenuEcolog",
						abbr_hl_group = "CmpItemAbbrMatchEcolog",
					})
				end

				callback({ items = items, isIncomplete = false })
			end,
		})
	end

	-- Allow custom providers through setup
	if opts.providers then
		for _, provider in ipairs(opts.providers) do
			if type(provider) == "table" and provider[1] then
				providers.register_many(provider)
			else
				providers.register(provider)
			end
		end
	end

	-- Create commands
	api.nvim_create_user_command("EnvPeek", function(args)
		peek.peek_env_value(args.args, opts, env_vars, providers, parse_env_file)
	end, {
		nargs = "?",
		desc = "Peek at environment variable value",
	})

	api.nvim_create_user_command("EnvRefresh", function()
		M.refresh_env_vars(opts)
	end, {
		desc = "Refresh environment variables cache",
	})

	api.nvim_create_user_command("EnvSelect", function()
		select.select_env_file(opts, function(file)
			if file then
				opts.preferred_environment = vim.fn.fnamemodify(file, ":t"):gsub("^%.env%.", "")
				M.refresh_env_vars(opts)
				notify("Switched to environment file: " .. vim.fn.fnamemodify(file, ":t"), vim.log.levels.INFO)
			end
		end)
	end, {
		desc = "Select environment file to use",
	})
end

return M