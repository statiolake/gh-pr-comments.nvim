local M = {}

function M.is_nil_like(value)
  return value == nil or value == vim.NIL
end

function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.normalize_newlines(text)
  if M.is_nil_like(text) then
    return ""
  end

  return tostring(text):gsub("\r\n", "\n"):gsub("\r", "\n")
end

function M.starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

function M.split_lines(text)
  if text == "" then
    return {}
  end

  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

function M.join_lines(lines)
  return table.concat(lines, "\n")
end

function M.max_backtick_run(text)
  local max_len = 0
  for ticks in tostring(text):gmatch("`+") do
    if #ticks > max_len then
      max_len = #ticks
    end
  end
  return max_len
end

function M.deepcopy(value)
  return vim.deepcopy(value)
end

function M.to_string_or_nil(value)
  if M.is_nil_like(value) then
    return nil
  end

  if type(value) == "string" then
    return value
  end

  return tostring(value)
end

function M.to_number_or_nil(value)
  if M.is_nil_like(value) then
    return nil
  end

  if type(value) == "number" then
    return value
  end

  if type(value) == "string" and value ~= "" then
    return tonumber(value)
  end

  return nil
end

function M.json_encode(value)
  return vim.json.encode(value)
end

function M.json_decode(value)
  return vim.json.decode(value)
end

function M.shell_error(result, context)
  local stderr = M.trim(result.stderr or "")
  local stdout = M.trim(result.stdout or "")
  local detail = stderr ~= "" and stderr or stdout
  if detail == "" then
    detail = "unknown error"
  end

  return string.format("%s: %s", context, detail)
end

return M
