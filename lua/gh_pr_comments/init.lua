local buffer = require("gh_pr_comments.buffer")
local qf = require("gh_pr_comments.qf")

local M = {}

function M.open(opts)
  buffer.open(opts or {})
end

function M.review_comment_qf_items(opts)
  return qf.review_comment_items(opts or {})
end

return M
