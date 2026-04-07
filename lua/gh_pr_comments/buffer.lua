local model = require("gh_pr_comments.model")
local parser = require("gh_pr_comments.parser")
local render = require("gh_pr_comments.render")
local sync = require("gh_pr_comments.sync")

local M = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, {
    title = "gh-pr-comments.nvim",
  })
end

local function render_into_buffer(bufnr, doc)
  local lines = render.render(doc)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.b[bufnr].gh_pr_comments_doc = doc
  vim.bo[bufnr].modified = false
end

local function buffer_name(doc)
  return string.format("gh-comment://%s/%d", doc.meta.kind, doc.meta.number)
end

local function buffer_name_for(kind, number)
  return string.format("gh-comment://%s/%d", kind, number)
end

local function find_existing_buffer(number)
  local candidates = {
    buffer_name_for("pull_request", number),
    buffer_name_for("issue", number),
  }

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      for _, candidate in ipairs(candidates) do
        if name == candidate then
          return bufnr
        end
      end
    end
  end

  return nil
end

local function load_doc(opts)
  return model.load({
    number = opts.number,
    cwd = vim.loop.cwd(),
  })
end

local function on_write(bufnr)
  local original_doc = vim.b[bufnr].gh_pr_comments_doc
  if not original_doc then
    notify("missing original document state", vim.log.levels.ERROR)
    return
  end

  local edited_doc, parse_err = parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  if parse_err then
    notify("parse error: " .. parse_err, vim.log.levels.ERROR)
    return
  end

  notify(string.format("saving comments for #%d", original_doc.meta.number))
  local refreshed, sync_err, report = sync.apply(edited_doc, original_doc, {
    cwd = vim.loop.cwd(),
  })
  if sync_err then
    notify("sync error: " .. sync_err, vim.log.levels.ERROR)
    return
  end

  for _, item in ipairs(report.updated or {}) do
    notify(string.format("updated %s %s", item.scope, tostring(item.id)))
  end

  for _, item in ipairs(report.skipped or {}) do
    notify(string.format("skipped %s %s: %s", item.scope, tostring(item.id), item.reason), vim.log.levels.WARN)
  end

  for _, item in ipairs(report.errored or {}) do
    notify(string.format("error %s %s: %s", item.scope, tostring(item.id), item.message), vim.log.levels.ERROR)
  end

  render_into_buffer(bufnr, refreshed)
  notify(string.format("saved comments for #%d", refreshed.meta.number))
end

function M.open(opts)
  notify(opts.number and string.format("loading comments for #%d", opts.number) or "loading current pull request comments")
  if opts.number then
    local existing = find_existing_buffer(opts.number)
    if existing then
      vim.api.nvim_set_current_buf(existing)
      local existing_doc = vim.b[existing].gh_pr_comments_doc
      if existing_doc then
        notify(string.format("activated existing comments buffer for %s #%d", existing_doc.meta.kind == "pull_request" and "PR" or "issue", existing_doc.meta.number))
      else
        notify(string.format("activated existing comments buffer for #%d", opts.number))
      end
      return
    end
  end

  local doc, err = load_doc(opts)
  if err then
    notify(err, vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, buffer_name(doc))
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      on_write(bufnr)
    end,
  })

  render_into_buffer(bufnr, doc)
  vim.api.nvim_set_current_buf(bufnr)
  notify(string.format("loaded comments for %s #%d", doc.meta.kind == "pull_request" and "PR" or "issue", doc.meta.number))
end

return M
