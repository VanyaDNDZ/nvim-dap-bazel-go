local M = {}

--------------------------------------------------------------------------------
-- TreeSitter queries for discovering Go tests/subtests
--------------------------------------------------------------------------------

local tests_query = [[
(function_declaration
  name: (identifier) @testname
  parameters: (parameter_list
    . (parameter_declaration
      type: (pointer_type) @type) .)
  (#match? @type "*testing.(T|M)")
  (#match? @testname "^Test.+$")) @parent
]]

local subtests_query = [[
(call_expression
  function: (selector_expression
    operand: (identifier)
    field: (field_identifier) @run)
  arguments: (argument_list
    (interpreted_string_literal) @testname
    [
     (func_literal)
     (identifier)
    ])
  (#eq? @run "Run")) @parent
]]

local function format_subtest(testcase, test_tree)
	if testcase.parent then
		for _, curr in ipairs(test_tree) do
			if curr.name == testcase.parent then
				return string.format("%s/%s", format_subtest(curr, test_tree), testcase.name)
			end
		end
	end
	return testcase.name
end

local function is_parent(dest, source)
	if not (dest and source) or dest == source then
		return false
	end
	local current = source
	while current ~= nil do
		if current == dest then
			return true
		end
		current = current:parent()
	end
	return false
end

local function get_closest_above_cursor(test_tree)
	local result
	for _, curr in pairs(test_tree) do
		if not result then
			result = curr
		else
			local node_row1 = curr.node:range()
			local result_row1 = result.node:range()
			-- we pick whichever is furthest down (closest above cursor)
			if node_row1 > result_row1 then
				result = curr
			end
		end
	end
	if result then
		return format_subtest(result, test_tree)
	end
	return nil
end

local function get_closest_test()
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local ft = vim.bo.filetype
	assert(ft == "go", "This only works in Go files")

	local parser = vim.treesitter.get_parser(0, "go")
	local root = (parser:parse()[1]):root()
	local test_tree = {}

	-- find top-level tests
	local test_query = vim.treesitter.query.parse("go", tests_query)
	for _, match, _ in test_query:iter_matches(root, 0, 0, row, { all = true }) do
		local item = {}
		for id, nodes in pairs(match) do
			for _, node in ipairs(nodes) do
				local capture = test_query.captures[id]
				if capture == "testname" then
					item.name = vim.treesitter.get_node_text(node, 0)
				elseif capture == "parent" then
					item.node = node
				end
			end
		end
		table.insert(test_tree, item)
	end

	-- find subtests
	local subtest_query = vim.treesitter.query.parse("go", subtests_query)
	for _, match, _ in subtest_query:iter_matches(root, 0, 0, row, { all = true }) do
		local item = {}
		for id, nodes in pairs(match) do
			for _, node in ipairs(nodes) do
				local capture = subtest_query.captures[id]
				if capture == "testname" then
					local txt = vim.treesitter.get_node_text(node, 0)
					txt = txt:gsub(" ", "_"):gsub('"', "")
					item.name = txt
				elseif capture == "parent" then
					item.node = node
				end
			end
		end
		table.insert(test_tree, item)
	end

	-- sort so parent nodes appear before children
	table.sort(test_tree, function(a, b)
		return is_parent(a.node, b.node)
	end)

	-- mark subtest parents
	for _, parent in ipairs(test_tree) do
		for _, child in ipairs(test_tree) do
			if is_parent(parent.node, child.node) then
				child.parent = parent.name
			end
		end
	end

	return get_closest_above_cursor(test_tree)
end

M.closest_test = function()
	local name = get_closest_test()
	return { name = name } -- subtest name (string) or nil
end

return M
