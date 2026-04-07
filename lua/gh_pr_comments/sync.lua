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

local function thread_by_root_id(doc)
  local map = {}
  for _, thread in ipairs(doc.review_threads or {}) do
    map[thread.root_id] = thread
  end
  return map
end

local function sync_existing_comment(repo, edited, original, opts)
  if edited.body == original.body then
    return "unchanged", nil
  end

  if not original.viewer_can_update then
    return "non_editable", nil
  end

  if edited.meta.kind == "issue_comment" then
    local _, err = gh.update_issue_comment(repo, edited.meta.id, edited.body, opts)
    if err then
      return "error", err
    end
    return "updated", nil
  end

  if edited.meta.kind == "review" then
    local _, err = gh.update_review(repo, opts.number, edited.meta.id, edited.body, opts)
    if err then
      return "error", err
    end
    return "updated", nil
  end

  local _, err = gh.update_review_comment(repo, edited.meta.id, edited.body, opts)
  if err then
    return "error", err
  end
  return "updated", nil
end

local function sync_item_body(edited_doc, original_doc, opts)
  if edited_doc.body == original_doc.body then
    return "unchanged", nil
  end

  if not original_doc.meta.body_viewer_can_update then
    return "non_editable", nil
  end

  if original_doc.meta.kind == "pull_request" then
    local _, err = gh.update_pull_request(original_doc.meta.repo, original_doc.meta.number, edited_doc.body, opts)
    if err then
      return "error", err
    end
    return "updated", nil
  end

  local _, err = gh.update_issue(original_doc.meta.repo, original_doc.meta.number, edited_doc.body, opts)
  if err then
    return "error", err
  end
  return "updated", nil
end

local function sync_new_comment(repo, number, edited, opts)
  if edited.body == "" then
    return "unchanged", nil
  end

  if edited.meta.kind == "new_issue_comment" then
    local _, err = gh.create_issue_comment(repo, number, edited.body, opts)
    if err then
      return "error", err
    end
    return "created", nil
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
    if err then
      return "error", err
    end
    return "created", nil
  end

  local _, err = gh.create_review_comment(repo, number, {
    body = edited.body,
    in_reply_to = edited.meta.in_reply_to_id,
  }, opts)
  if err then
    return "error", err
  end
  return "created", nil
end

local function overlay_failed_edits(doc, failed_items)
  local by_existing_id = by_id(doc)
  local by_thread_root = thread_by_root_id(doc)

  for _, failed in ipairs(failed_items) do
    local edited = failed.edited
    if failed.scope == "body" then
      doc.body = edited.body
    elseif edited.meta.id and by_existing_id[edited.meta.id] then
      by_existing_id[edited.meta.id].body = edited.body
    elseif edited.meta.kind == "new_issue_comment" then
      table.insert(doc.timeline_items, {
        kind = "pending_issue_comment",
        author = doc.meta.current_user,
        body = edited.body,
      })
    elseif edited.meta.kind == "new_review_comment" then
      table.insert(doc.review_threads, {
        root_id = nil,
        comments = {
          {
            kind = "pending_review_comment",
            author = doc.meta.current_user,
            body = edited.body,
            target = edited.meta.target,
          },
        },
      })
    elseif edited.meta.kind == "new_review_reply" then
      local thread = by_thread_root[edited.meta.in_reply_to_id]
      if thread then
        table.insert(thread.comments, {
          kind = "pending_review_reply",
          author = doc.meta.current_user,
          body = edited.body,
          in_reply_to_id = edited.meta.in_reply_to_id,
        })
      end
    end
  end
end

function M.apply(edited_doc, original_doc, opts)
  local repo = original_doc.meta.repo
  local number = original_doc.meta.number
  local original_by_id = by_id(original_doc)
  opts = vim.tbl_extend("force", { number = number }, opts or {})
  local report = {
    updated = {},
    errored = {},
    skipped = {},
  }

  local failed_items = {}

  local body_status, body_err = sync_item_body(edited_doc, original_doc, opts)
  if body_status == "updated" then
    table.insert(report.updated, { scope = "body", id = "body" })
  elseif body_status == "non_editable" then
    table.insert(report.skipped, { scope = "body", id = "body", reason = "not editable by the current user" })
  elseif body_status == "error" then
    table.insert(report.errored, { scope = "body", id = "body", message = body_err })
    table.insert(failed_items, {
      scope = "body",
      edited = { body = edited_doc.body },
    })
  end

  for _, edited in ipairs(edited_doc.comments) do
    local kind = edited.meta.kind
    if kind == "issue_comment" or kind == "review_comment" or kind == "review" then
      local original = original_by_id[edited.meta.id]
      if not original then
        return nil, string.format("comment #%d is unknown in the original document", edited.meta.id)
      end

      local status, err = sync_existing_comment(repo, edited, original, opts)
      if status == "updated" then
        table.insert(report.updated, { scope = kind, id = edited.meta.id })
      elseif status == "non_editable" then
        table.insert(report.skipped, { scope = kind, id = edited.meta.id, reason = "not editable by the current user" })
      elseif status == "error" then
        table.insert(report.errored, { scope = kind, id = edited.meta.id, message = err })
        table.insert(failed_items, { scope = kind, edited = edited })
      end
    else
      local status, err = sync_new_comment(repo, number, edited, opts)
      if status == "created" then
        table.insert(report.updated, { scope = kind, id = edited.meta.id or "new" })
      elseif status == "error" then
        table.insert(report.errored, { scope = kind, id = edited.meta.id or "new", message = err })
        table.insert(failed_items, { scope = kind, edited = edited })
      end
    end
  end

  local refreshed, load_err = model.load({
    number = number,
    cwd = opts.cwd,
  })
  if load_err then
    return nil, load_err
  end

  overlay_failed_edits(refreshed, failed_items)

  return refreshed, nil, report
end

return M
