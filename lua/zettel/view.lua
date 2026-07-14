local M = {}

local cache = require("zettel.cache")

local function trim_quotes(value)
	value = vim.trim(tostring(value or ""))
	return value:gsub('^["\']', ""):gsub('["\']$', "")
end

local function parse_list(value)
	value = vim.trim(tostring(value or ""))
	value = value:gsub("^%[", ""):gsub("%]$", "")

	local result = {}
	for item in value:gmatch("[^,]+") do
		item = trim_quotes(item)
		if item ~= "" then
			table.insert(result, item)
		end
	end
	return result
end

local function contains_ignore_case(values, wanted)
	wanted = tostring(wanted):lower()
	for _, value in ipairs(values or {}) do
		if tostring(value):lower() == wanted then
			return true
		end
	end
	return false
end

local function get_all_views()
	local results = {}
	for _, note in ipairs(cache.notes) do
		if contains_ignore_case(note.tags, "view") then
			table.insert(results, {
				file = note.path,
				title = note.title or vim.fn.fnamemodify(note.path, ":t:r"),
			})
		end
	end

	table.sort(results, function(a, b)
		return a.title:lower() < b.title:lower()
	end)
	return results
end

local function parse_view(view_file)
	local lines = vim.fn.readfile(view_file)
	local in_block = false
	local filters = {}

	for _, line in ipairs(lines) do
		if line:match("^%s*```view%s*$") then
			in_block = true
		elseif line:match("^%s*```%s*$") and in_block then
			break
		elseif in_block then
			local key, value = line:match("^%s*([%w_-]+)%s*:%s*(.-)%s*$")
			if key and value and value ~= "" then
				key = key:lower()
				if key == "tags" then
					filters.tags = parse_list(value)
				else
					filters[key] = trim_quotes(value)
				end
			end
		end
	end

	return filters
end

local function normalize_date(value)
	value = trim_quotes(value)
	if value == "" then
		return nil
	end

	local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
	if year then
		return string.format("%s-%s-%s", year, month, day)
	end

	day, month, year = value:match("^(%d%d?)%.(%d%d?)%.(%d%d%d%d)$")
	if year then
		return string.format("%04d-%02d-%02d", tonumber(year), tonumber(month), tonumber(day))
	end

	return nil
end

local function resolve_note_date(note)
	return normalize_date(note.published)
		or normalize_date(note.date)
		or normalize_date(note.id)
		or (note.mtime and note.mtime > 0 and os.date("%Y-%m-%d", note.mtime))
end

local function matches_tags(note_tags, filter_tags)
	if not filter_tags or #filter_tags == 0 then
		return true
	end

	-- Every tag listed in the view must be present on the note.
	for _, wanted in ipairs(filter_tags) do
		if not contains_ignore_case(note_tags, wanted) then
			return false
		end
	end
	return true
end

local function run_query(filters)
	local results = {}
	local minimum_date = normalize_date(filters.date)

	for _, note in ipairs(cache.notes) do
		if not matches_tags(note.tags, filters.tags) then
			goto continue
		end

		if filters.status and tostring(note.status or ""):lower() ~= filters.status:lower() then
			goto continue
		end

		local note_date = resolve_note_date(note)
		if minimum_date and (not note_date or note_date < minimum_date) then
			goto continue
		end

		table.insert(results, {
			path = note.path,
			title = note.title or vim.fn.fnamemodify(note.path, ":t:r"),
			tags = note.tags or {},
			status = note.status,
			date = note_date,
			mtime = note.mtime or 0,
		})
		::continue::
	end

	local descending = tostring(filters.order or "desc"):lower() ~= "asc"
	table.sort(results, function(a, b)
		local ad = a.date or "0000-00-00"
		local bd = b.date or "0000-00-00"

		if ad ~= bd then
			if descending then
				return ad > bd
			end
			return ad < bd
		end

		if a.mtime ~= b.mtime then
			if descending then
				return a.mtime > b.mtime
			end
			return a.mtime < b.mtime
		end

		local at = tostring(a.title or ""):lower()
		local bt = tostring(b.title or ""):lower()
		if at ~= bt then
			return at < bt
		end

		-- Final deterministic tie-breaker. Returning false for identical
		-- entries is required by Lua's table.sort comparator contract.
		return tostring(a.path or "") < tostring(b.path or "")
	end)

	return results
end

local function show_query_results(filters)
	-- Always rebuild here. This avoids stale metadata when a note was changed
	-- outside Neovim or before the BufWritePost autocmd ran.
	cache.build_cache()
	local results = run_query(filters)

	if #results == 0 then
		vim.notify("Zettel view: no matching notes", vim.log.levels.WARN)
		return
	end

	require("telescope.pickers").new({}, {
		prompt_title = "View Results (newest first)",
		finder = require("telescope.finders").new_table({
			results = results,
			entry_maker = function(note)
				local status = note.status and note.status ~= "" and note.status or "-"
				local date = note.date or "----------"
				return {
					value = note.path,
					path = note.path,
					display = string.format("%s  [%-9s]  %s", date, status, note.title),
					ordinal = string.format("%s %s %s %s", note.title, status, date, table.concat(note.tags, " ")),
				}
			end,
		}),
		-- An empty sorter preserves the order supplied by run_query. The generic
		-- Telescope sorter otherwise reorders entries by title/relevance.
		sorter = require("telescope.sorters").empty(),
		previewer = require("telescope.config").values.file_previewer({}),
		attach_mappings = function(_, map)
			local function open_selection(bufnr)
				local selection = require("telescope.actions.state").get_selected_entry()
				require("telescope.actions").close(bufnr)
				if selection then
					vim.cmd("edit " .. vim.fn.fnameescape(selection.value))
				end
			end
			map("i", "<CR>", open_selection)
			map("n", "<CR>", open_selection)
			return true
		end,
	}):find()
end

local function show_views_list()
	cache.build_cache()
	local views = get_all_views()
	if #views == 0 then
		vim.notify("No views found", vim.log.levels.WARN)
		return
	end

	local lines = {}
	for i, view in ipairs(views) do
		table.insert(lines, string.format("%d. %s", i, view.title))
	end

	local width = math.floor(vim.o.columns * 0.5)
	local height = #lines + 2
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " VIEWS ",
	})

	vim.keymap.set("n", "<CR>", function()
		local selected = views[vim.fn.line(".")]
		vim.api.nvim_win_close(win, true)
		if selected then
			show_query_results(parse_view(selected.file))
		end
	end, { buffer = buf, nowait = true })

	vim.keymap.set("n", "<Esc>", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf, nowait = true })
end

M.show_views_list = show_views_list
M._parse_view = parse_view
M._run_query = run_query
M._resolve_note_date = resolve_note_date

return M
