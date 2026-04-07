local util = require("gh_pr_comments.util")

local M = {}
local LONG_COMMENT_FOLD_THRESHOLD = 10
local FOLD_START = " <!-- {{{ -->"
local FOLD_END = " <!-- }}} -->"

local function add_block(lines, block_lines)
  if #lines > 0 and lines[#lines] ~= "" then
    table.insert(lines, "")
  end

  vim.list_extend(lines, block_lines)
end

local function add_separator(lines)
  if #lines > 0 and lines[#lines] ~= "" then
    table.insert(lines, "")
  end
  table.insert(lines, "---")
  table.insert(lines, "")
end

local function append_fenced_body(lines, body)
  local normalized = util.normalize_newlines(body)
  local fence = string.rep("`", math.max(3, util.max_backtick_run(normalized) + 1))
  table.insert(lines, fence .. "comment")

  local body_lines = util.split_lines(normalized)
  vim.list_extend(lines, body_lines)

  table.insert(lines, fence)
end

local function should_fold_long_comment(body)
  local normalized = util.normalize_newlines(body)
  local body_lines = util.split_lines(normalized)
  return #body_lines >= LONG_COMMENT_FOLD_THRESHOLD
end

local function render_comment_label(comment)
  local is_review = comment.kind == "review"
  local has_id = comment.id ~= nil
  local kind_label = is_review and "review" or "comment"
  local id_label = has_id and string.format(" %s#%s", kind_label, comment.id) or ""

  if is_review then
    return string.format("@%s%s [%s]", comment.author, id_label, comment.state)
  end

  return string.format("@%s%s", comment.author, id_label)
end

local function build_comment_block(comment)
  local block = {
    render_comment_label(comment),
    "",
  }

  append_fenced_body(block, comment.body)

  if should_fold_long_comment(comment.body) then
    block[1] = block[1] .. FOLD_START
    block[#block] = block[#block] .. FOLD_END
  end

  return block
end

function M.render(doc)
  local lines = {
    string.format("# %s #%d: %s", doc.meta.kind == "pull_request" and "Pull Request" or "Issue", doc.meta.number, doc.meta.title),
    "",
    doc.meta.url,
    "",
    "## Description",
    "",
  }
  append_fenced_body(lines, doc.body)

  table.insert(lines, "")
  table.insert(lines, "## Comments")

  local timeline_items = doc.timeline_items or {}
  if #timeline_items > 0 then
    table.insert(lines, "")
  end

  for index, comment in ipairs(timeline_items) do
    if index > 1 then
      add_separator(lines)
    end

    add_block(lines, build_comment_block(comment))
  end

  if doc.meta.kind == "pull_request" then
    table.insert(lines, "")
    table.insert(lines, "## Reviews")

    local review_threads = doc.review_threads or {}
    if #review_threads > 0 then
      table.insert(lines, "")
    end

    for _, thread in ipairs(review_threads) do
      local first = thread.comments[1]
      local location = string.format("%s:%s", first.path or "unknown", tostring(first.line or "?"))
      local block = {
        string.format("### %s", location),
      }

      for index, comment in ipairs(thread.comments) do
        if index == 1 then
          table.insert(block, "")
        else
          table.insert(block, "")
          table.insert(block, "---")
          table.insert(block, "")
        end

        vim.list_extend(block, build_comment_block(comment))
      end

      local last_comment = thread.comments[#thread.comments]
      if last_comment and last_comment.author == doc.meta.current_user then
        block[1] = block[1] .. FOLD_START
        block[#block] = block[#block] .. FOLD_END
      end

      add_block(lines, block)
    end
  end

  return lines
end

return M
