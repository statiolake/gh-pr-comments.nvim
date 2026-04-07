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
      if comment.kind == "review_comment" and comment.path and comment.line then
        table.insert(items, {
          filename = comment.path,
          lnum = comment.line,
          col = 1,
          text = string.format("@%s: %s", comment.author, comment.body:gsub("%s+", " ")),
          user_data = {
            gh_pr_comments = {
              id = comment.id,
              kind = comment.kind,
              in_reply_to_id = comment.in_reply_to_id,
              commit_id = comment.commit_id,
              path = comment.path,
              line = comment.line,
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
