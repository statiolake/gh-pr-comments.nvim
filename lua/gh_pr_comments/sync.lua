local gh = require("gh_pr_comments.gh")
local model = require("gh_pr_comments.model")
local target = require("gh_pr_comments.target")

local M = {}

local function by_id(doc)
  local map = {}
  for _, item in ipairs(doc.timeline_items or {}) do
    map[item.id] = item
  end

  for _, thread in ipairs(doc.review_threads or {}) do
    for _, comment in ipairs(thread.comments) do
      map[comment.id] = comment
    end
  end
  return map
end

local function sync_existing_comment(repo, edited, original, opts)
  if edited.body == original.body then
    return nil
  end

  if not original.viewer_can_update then
    return string.format("comment #%d is not editable by the current user", edited.meta.id)
  end

  if edited.meta.kind == "issue_comment" then
    local _, err = gh.update_issue_comment(repo, edited.meta.id, edited.body, opts)
    return err
  end

  if edited.meta.kind == "review" then
    local _, err = gh.update_review(repo, opts.number, edited.meta.id, edited.body, opts)
    return err
  end

  local _, err = gh.update_review_comment(repo, edited.meta.id, edited.body, opts)
  return err
end

local function sync_item_body(edited_doc, original_doc, opts)
  if edited_doc.body == original_doc.body then
    return nil
  end

  if not original_doc.meta.body_viewer_can_update then
    return "item body is not editable by the current user"
  end

  if original_doc.meta.kind == "pull_request" then
    local _, err = gh.update_pull_request(original_doc.meta.repo, original_doc.meta.number, edited_doc.body, opts)
    return err
  end

  local _, err = gh.update_issue(original_doc.meta.repo, original_doc.meta.number, edited_doc.body, opts)
  return err
end

local function sync_new_comment(repo, number, edited, opts)
  if edited.body == "" then
    return nil
  end

  if edited.meta.kind == "new_issue_comment" then
    local _, err = gh.create_issue_comment(repo, number, edited.body, opts)
    return err
  end

  if edited.meta.kind == "new_review" then
    local _, err = gh.create_review(repo, number, {
      body = edited.body,
      event = edited.meta.state,
    }, opts)
    return err
  end

  if edited.meta.kind == "new_review_comment" then
    local parsed_target, target_err = target.parse_blob_url(edited.meta.target)
    if target_err then
      return target_err
    end

    if parsed_target.repo ~= repo then
      return string.format("review target repo %s does not match current repo %s", parsed_target.repo, repo)
    end

    local _, err = gh.create_review_comment(repo, number, {
      body = edited.body,
      path = parsed_target.path,
      line = parsed_target.line,
      side = edited.meta.side,
      commit_id = parsed_target.commit_id,
    }, opts)
    return err
  end

  local _, err = gh.create_review_comment(repo, number, {
    body = edited.body,
    in_reply_to = edited.meta.in_reply_to_id,
  }, opts)
  return err
end

function M.apply(edited_doc, original_doc, opts)
  local repo = original_doc.meta.repo
  local number = original_doc.meta.number
  local original_by_id = by_id(original_doc)
  opts = vim.tbl_extend("force", { number = number }, opts or {})

  local body_err = sync_item_body(edited_doc, original_doc, opts)
  if body_err then
    return nil, body_err
  end

  for _, edited in ipairs(edited_doc.comments) do
    local kind = edited.meta.kind
    if kind == "issue_comment" or kind == "review_comment" or kind == "review" then
      local original = original_by_id[edited.meta.id]
      if not original then
        return nil, string.format("comment #%d is unknown in the original document", edited.meta.id)
      end

      local err = sync_existing_comment(repo, edited, original, opts)
      if err then
        return nil, err
      end
    else
      local err = sync_new_comment(repo, number, edited, opts)
      if err then
        return nil, err
      end
    end
  end

  return model.load({
    number = number,
    cwd = opts.cwd,
  })
end

return M
