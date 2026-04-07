local util = require("gh_pr_comments.util")

local M = {}
local validate_comment
local function strip_fold_markers(line)
  if type(line) ~= "string" then
    return line
  end

  local stripped = line
  stripped = stripped:gsub("%s*<!%-%- %{%{%{ %-%->$", "")
  stripped = stripped:gsub("%s*<!%-%- %}%}%} %-%->$", "")
  return stripped
end

local function consume_fenced_body(lines, start_index, meta_lnum)
  local index = start_index
  while index <= #lines and strip_fold_markers(lines[index]) == "" do
    index = index + 1
  end

  local opening = strip_fold_markers(lines[index])
  if not opening then
    return nil, nil, string.format("line %d: missing fenced body after metadata", meta_lnum)
  end

  local fence = opening:match("^(```+)%S*$")
  if not fence then
    return nil, nil, string.format("line %d: expected fenced body after metadata", meta_lnum)
  end

  local body = {}
  index = index + 1

  while index <= #lines do
    local current = strip_fold_markers(lines[index])
    if current == fence then
      return util.join_lines(body), index + 1, nil
    end

    table.insert(body, current)
    index = index + 1
  end

  return nil, nil, string.format("line %d: unterminated fenced body", meta_lnum)
end

local function consume_plain_body(lines, start_index, is_boundary)
  local index = start_index
  local body = {}

  while index <= #lines do
    local current = strip_fold_markers(lines[index])
    if current == "" then
      index = index + 1
    elseif is_boundary(current, index) then
      break
    else
      table.insert(body, current)
      index = index + 1
    end
  end

  while #body > 0 and body[1] == "" do
    table.remove(body, 1)
  end

  while #body > 0 and body[#body] == "" do
    table.remove(body, #body)
  end

  return util.join_lines(body), index, nil
end

local function consume_body(lines, start_index, meta_lnum, is_boundary)
  local index = start_index
  while index <= #lines and strip_fold_markers(lines[index]) == "" do
    index = index + 1
  end

  local opening = strip_fold_markers(lines[index])
  if not opening then
    return "", index, nil
  end

  if opening:match("^```+") then
    return consume_fenced_body(lines, index, meta_lnum)
  end

  return consume_plain_body(lines, index, is_boundary)
end

local function next_nonblank_line(lines, start_index)
  local index = start_index
  while index <= #lines and lines[index] == "" do
    index = index + 1
  end
  return index, lines[index]
end

local function parse_identity_line(line)
  if type(line) ~= "string" or not line:match("^@") then
    return nil
  end

  local author, kind, id, state = line:match("^@([^%s]+)%s+([a-z_]+)#(%d+)%s+%[([A-Z_]+)%]$")
  if author and kind and id then
    return {
      author = author,
      kind = kind == "review" and "review" or "unknown",
      id = tonumber(id),
      state = state,
    }
  end

  author, kind, id = line:match("^@([^%s]+)%s+([a-z_]+)#(%d+)$")
  if author and kind and id then
    return {
      author = author,
      kind = kind == "review" and "review" or "comment",
      id = tonumber(id),
    }
  end

  author = line:match("^@([^%s]+)$")
  if author then
    return {
      author = author,
      kind = "new_reply_author_only",
    }
  end

  return nil
end

local function parse_review_thread_heading(line)
  if type(line) ~= "string" then
    return nil
  end

  local url = line:match("^### (https://github%.com/.+)$")
  if url then
    return {
      mode = "url",
      value = url,
    }
  end

  local path, line_number = line:match("^### (.+):(%d+)$")
  if path and line_number then
    return {
      mode = "location",
      path = path,
      line = tonumber(line_number),
    }
  end

  return nil
end

local function parse_timeline_entry(lines, start_index)
  local index = start_index
  local identity = parse_identity_line(lines[index])
  if identity then
    index = index + 1
  end

  local meta
  if identity and identity.id then
    if identity.kind == "review" then
      meta = {
        kind = "review",
        id = identity.id,
        state = identity.state,
      }
    else
      meta = {
        kind = "issue_comment",
        id = identity.id,
      }
    end
  else
    meta = { kind = "new_issue_comment" }
  end

  local body, after_body, body_err = consume_body(lines, index, start_index, function(line)
    return line == "---" or line == "## Reviews"
  end)
  if body_err then
    return nil, nil, body_err
  end

  local comment, comment_err = validate_comment(meta, body, start_index)
  if comment_err then
    return nil, nil, comment_err
  end

  return comment, after_body, nil
end

local function parse_review_thread_entry(lines, start_index, thread_context, thread_root_id)
  local index = start_index
  local identity = parse_identity_line(lines[index])
  if identity then
    index = index + 1
  end

  local meta
  if identity and identity.id then
    meta = {
      kind = "review_comment",
      id = identity.id,
    }
  else
    if thread_root_id then
      meta = {
        kind = "new_review_reply",
        in_reply_to_id = thread_root_id,
      }
    else
      if not thread_context or thread_context.mode ~= "url" then
        return nil, nil, string.format("line %d: new review thread requires a GitHub blob URL heading", start_index)
      end

      meta = {
        kind = "new_review_comment",
        target = thread_context.value,
        side = "RIGHT",
      }
    end
  end

  local body, after_body, body_err = consume_body(lines, index, start_index, function(line)
    return line == "---" or parse_review_thread_heading(line) ~= nil
  end)
  if body_err then
    return nil, nil, body_err
  end

  local comment, comment_err = validate_comment(meta, body, start_index)
  if comment_err then
    return nil, nil, comment_err
  end

  return comment, after_body, nil
end

validate_comment = function(meta, body, lnum)
  local kind = meta.kind
  if kind == "issue_comment" or kind == "review_comment" then
    if type(meta.id) ~= "number" then
      return nil, string.format("line %d: existing comment requires numeric id", lnum)
    end
  elseif kind == "review" then
    if type(meta.id) ~= "number" then
      return nil, string.format("line %d: existing review requires numeric id", lnum)
    end
    if meta.state ~= "COMMENTED" and meta.state ~= "APPROVED" and meta.state ~= "CHANGES_REQUESTED" then
      return nil, string.format("line %d: existing review requires known state", lnum)
    end
  elseif kind == "new_issue_comment" then
    -- no extra validation
  elseif kind == "new_review" then
    if meta.state ~= "COMMENT" and meta.state ~= "APPROVE" and meta.state ~= "REQUEST_CHANGES" then
      return nil, string.format("line %d: new review requires state COMMENT, APPROVE, or REQUEST_CHANGES", lnum)
    end
  elseif kind == "new_review_comment" then
    if type(meta.target) ~= "string" or meta.target == "" then
      return nil, string.format("line %d: new review comment requires target GitHub blob URL", lnum)
    end
    if meta.side ~= "LEFT" and meta.side ~= "RIGHT" then
      return nil, string.format("line %d: new review comment requires side LEFT or RIGHT", lnum)
    end
  elseif kind == "new_review_reply" then
    if type(meta.in_reply_to_id) ~= "number" then
      return nil, string.format("line %d: new review reply requires numeric in_reply_to_id", lnum)
    end
  else
    return nil, string.format("line %d: unsupported comment kind %q", lnum, tostring(kind))
  end

  return {
    meta = meta,
    body = body,
  }, nil
end

function M.parse(lines)
  if #lines == 0 then
    return nil, "buffer is empty"
  end

  local comments = {}
  local body
  local index = 1
  local section
  local current_thread_context
  local current_thread_root_id

  while index <= #lines do
    local line = strip_fold_markers(lines[index])
    if index == 1 and line:match("^# ") then
      index = index + 1
    elseif index == 3 and type(line) == "string" then
      index = index + 1
    elseif line == "## Comments" then
      section = "comments"
      current_thread_context = nil
      current_thread_root_id = nil
      index = index + 1
    elseif line == "## Reviews" then
      section = "reviews"
      current_thread_context = nil
      current_thread_root_id = nil
      index = index + 1
    elseif line == "## Description" then
      local parsed_body, next_index, body_err = consume_body(lines, index + 1, index, function(boundary_line)
        return boundary_line == "## Comments" or boundary_line == "## Reviews"
      end)
      if body_err then
        return nil, body_err
      end
      body = parsed_body
      index = next_index
    elseif line == "---" or line == "" then
      index = index + 1
    elseif section == "comments" then
      local comment, next_index, comment_err = parse_timeline_entry(lines, index)
      if comment_err then
        return nil, comment_err
      end
      table.insert(comments, comment)
      index = next_index
    elseif section == "reviews" and parse_review_thread_heading(line) then
      current_thread_context = parse_review_thread_heading(line)
      current_thread_root_id = nil
      index = index + 1
    elseif section == "reviews" and current_thread_context then
      local comment, next_index, comment_err = parse_review_thread_entry(lines, index, current_thread_context, current_thread_root_id)
      if comment_err then
        return nil, comment_err
      end
      table.insert(comments, comment)
      if comment.meta.kind == "review_comment" and not current_thread_root_id then
        current_thread_root_id = comment.meta.id
      end
      index = next_index
    elseif section == nil then
      return nil, string.format("line %d: unexpected content outside any section: %s", index, line)
    elseif section == "comments" then
      return nil, string.format("line %d: unexpected content in Comments section: %s", index, line)
    elseif section == "reviews" then
      return nil, string.format("line %d: unexpected content in Reviews section: %s", index, line)
    else
      return nil, string.format("line %d: unexpected content: %s", index, line)
    end
  end

  return {
    body = body or "",
    comments = comments,
  }, nil
end

return M
