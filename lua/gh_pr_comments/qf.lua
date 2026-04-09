local model = require("gh_pr_comments.model")

local M = {}

function M.review_comment_items(opts)
  local doc, err = model.load(opts)
  if err then
    error(err)
  end

  local items = {}
  for _, thread in ipairs(doc.review_threads or {}) do
    for _, comment in ipairs(thread.comments) do
      local path = comment.path or thread.path
      local line = comment.line or comment.original_line or thread.line
      if comment.kind == "review_comment" and path and line then
        table.insert(items, {
          filename = path,
          lnum = line,
          col = 1,
          text = string.format("@%s: %s", comment.author, comment.body:gsub("%s+", " ")),
          user_data = {
            gh_pr_comments = {
              id = comment.id,
              kind = comment.kind,
              in_reply_to_id = comment.in_reply_to_id,
              commit_id = comment.commit_id,
              path = path,
              line = line,
              side = comment.side,
            },
          },
        })
      end
    end
  end

  return items
end

return M
