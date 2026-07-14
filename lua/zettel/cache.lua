local M = {
	notes = {},
}

local config = require("zettel.config")
local utils = require("zettel.utils")

local function contains_template_placeholder(value)
	if type(value) == "string" then
		return value:match("%$[%w_-]+%$") ~= nil
	end
	if type(value) == "table" then
		for _, item in ipairs(value) do
			if contains_template_placeholder(item) then
				return true
			end
		end
	end
	return false
end

local function is_template_note(file, meta)
	-- Do not index unresolved template files such as title: $title$.
	-- This also covers templates stored outside the configured templates dir.
	if contains_template_placeholder(meta.id)
		or contains_template_placeholder(meta.title)
		or contains_template_placeholder(meta.tags)
		or contains_template_placeholder(meta.status) then
		return true
	end

	local templates_dir = vim.fn.fnamemodify(config.get_templates_dir(), ":p")
	local absolute_file = vim.fn.fnamemodify(file, ":p")
	return absolute_file:sub(1, #templates_dir) == templates_dir
end

---Scan and build cache for vault
function M.build_cache()
	M.notes = {}

	local vault = config.get_vault_dir()
	local ignore_dirs = config.get_ignore_dirs()

	-- Build a shell-safe ripgrep command. Keep the glob options outside the
	-- quoted vault path so paths containing spaces continue to work.
	local parts = { "rg", "--files" }
	for _, dir in ipairs(ignore_dirs) do
		table.insert(parts, "-g")
		table.insert(parts, vim.fn.shellescape("!" .. dir .. "/**"))
	end
	table.insert(parts, "-g")
	table.insert(parts, vim.fn.shellescape("*.md"))
	table.insert(parts, vim.fn.shellescape(vault))

	local handle = io.popen(table.concat(parts, " "))
	if not handle then
		return
	end

	for file in handle:lines() do
		local meta = utils.parse_frontmatter(file) or {}
		if not is_template_note(file, meta) then
			local file_mtime = vim.fn.getftime(file)

			table.insert(M.notes, {
				id = meta.id,
				title = meta.title or vim.fn.fnamemodify(file, ":t:r"),
				tags = meta.tags or {},
				status = meta.status,
				date = meta.date,
				published = meta.published,
				mtime = file_mtime,
				path = file,
			})
		end
	end

	handle:close()
end

return M
