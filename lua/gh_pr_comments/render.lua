local util = require("gh_pr_comments.util")

local M = {}

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

local function render_comment_label(comment)
  local kind_label = comment.kind == "review" and "review" or "comment"
  local id_label = string.format("%s#%s", kind_label, comment.id)

  if comment.kind == "review" then
    return string.format("@%s %s [%s]", comment.author, id_label, comment.state)
  end

  return string.format("@%s %s", comment.author, id_label)
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
  table.insert(lines, "# Comments")

  for index, comment in ipairs(doc.timeline_items or {}) do
    if index > 1 then
      add_separator(lines)
    else
      table.insert(lines, "")
    end

    local block = {
      render_comment_label(comment),
      "",
    }

    append_fenced_body(block, comment.body)

    add_block(lines, block)
  end

  add_separator(lines)
  local new_issue_block = {}
  append_fenced_body(new_issue_block, "")
  add_block(lines, new_issue_block)

  if doc.meta.kind == "pull_request" then
    table.insert(lines, "")
    table.insert(lines, "# Reviews")

    for thread_index, thread in ipairs(doc.review_threads or {}) do
      if thread_index > 1 then
        add_separator(lines)
      else
        table.insert(lines, "")
      end

      local first = thread.comments[1]
      local block = {
        string.format("## %s", first.target or "review thread"),
      }

      for index, comment in ipairs(thread.comments) do
        if index == 1 then
          table.insert(block, "")
        else
          table.insert(block, "")
          table.insert(block, "---")
          table.insert(block, "")
        end

        table.insert(block, string.format("@%s", comment.author))
        table.remove(block, #block)
        table.insert(block, render_comment_label(comment))
        table.insert(block, "")
        append_fenced_body(block, comment.body)
      end

      add_block(lines, block)
    end

    add_separator(lines)
    local new_comment_block = {
      "## https://github.com/OWNER/REPO/blob/COMMIT/PATH/TO/FILE#L1",
    }
    append_fenced_body(new_comment_block, "")
    add_block(lines, new_comment_block)
  end

  return lines
end

return M
