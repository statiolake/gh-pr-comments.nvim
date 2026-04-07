local util = require("gh_pr_comments.util")

local M = {}

local function run_gh(args, opts)
  local cmd = vim.list_extend({ "gh" }, args)
  local result = vim.system(cmd, {
    text = true,
    cwd = opts and opts.cwd or nil,
  }):wait()

  if result.code ~= 0 then
    return nil, util.shell_error(result, "gh command failed")
  end

  return result.stdout, nil
end

local function gh_json(args, opts)
  local stdout, err = run_gh(args, opts)
  if err then
    return nil, err
  end

  local ok, decoded = pcall(util.json_decode, stdout)
  if not ok then
    return nil, "failed to decode gh JSON response"
  end

  return decoded, nil
end

function M.repo_name(opts)
  local data, err = gh_json({ "repo", "view", "--json", "nameWithOwner" }, opts)
  if err then
    return nil, err
  end

  return data.nameWithOwner, nil
end

function M.current_user(opts)
  local data, err = gh_json({ "api", "user" }, opts)
  if err then
    return nil, err
  end

  return data.login, nil
end

function M.view_pull_request(number, opts)
  local args = { "pr", "view" }
  if number then
    table.insert(args, tostring(number))
  end
  vim.list_extend(args, {
    "--json",
    "number,title,body,url,author",
  })

  return gh_json(args, opts)
end

function M.view_issue(number, opts)
  local args = {
    "issue",
    "view",
    tostring(number),
    "--json",
    "number,title,body,url,author",
  }

  return gh_json(args, opts)
end

function M.issue_comments(repo, number, opts)
  return gh_json({
    "api",
    "--paginate",
    string.format("repos/%s/issues/%d/comments", repo, number),
  }, opts)
end

function M.review_comments(repo, number, opts)
  return gh_json({
    "api",
    "--paginate",
    string.format("repos/%s/pulls/%d/comments", repo, number),
  }, opts)
end

function M.reviews(repo, number, opts)
  return gh_json({
    "api",
    "--paginate",
    string.format("repos/%s/pulls/%d/reviews", repo, number),
  }, opts)
end

function M.create_issue_comment(repo, number, body, opts)
  return gh_json({
    "api",
    string.format("repos/%s/issues/%d/comments", repo, number),
    "-f",
    "body=" .. body,
  }, opts)
end

function M.update_issue_comment(repo, comment_id, body, opts)
  return gh_json({
    "api",
    string.format("repos/%s/issues/comments/%d", repo, comment_id),
    "-X",
    "PATCH",
    "-f",
    "body=" .. body,
  }, opts)
end

function M.update_issue(repo, number, body, opts)
  return gh_json({
    "api",
    string.format("repos/%s/issues/%d", repo, number),
    "-X",
    "PATCH",
    "-f",
    "body=" .. body,
  }, opts)
end

function M.create_review_comment(repo, number, payload, opts)
  local args = {
    "api",
    string.format("repos/%s/pulls/%d/comments", repo, number),
    "-f",
    "body=" .. payload.body,
  }

  if payload.in_reply_to then
    vim.list_extend(args, {
      "-F",
      "in_reply_to=" .. payload.in_reply_to,
    })
  else
    vim.list_extend(args, {
      "-f",
      "commit_id=" .. payload.commit_id,
      "-f",
      "path=" .. payload.path,
      "-F",
      "line=" .. payload.line,
      "-f",
      "side=" .. payload.side,
    })
  end

  return gh_json(args, opts)
end

function M.update_review_comment(repo, comment_id, body, opts)
  return gh_json({
    "api",
    string.format("repos/%s/pulls/comments/%d", repo, comment_id),
    "-X",
    "PATCH",
    "-f",
    "body=" .. body,
  }, opts)
end

function M.create_review(repo, number, payload, opts)
  local args = {
    "api",
    string.format("repos/%s/pulls/%d/reviews", repo, number),
    "-f",
    "body=" .. payload.body,
  }

  if payload.event then
    vim.list_extend(args, {
      "-f",
      "event=" .. payload.event,
    })
  end

  return gh_json(args, opts)
end

function M.update_review(repo, number, review_id, body, opts)
  return gh_json({
    "api",
    string.format("repos/%s/pulls/%d/reviews/%d", repo, number, review_id),
    "-X",
    "PUT",
    "-f",
    "body=" .. body,
  }, opts)
end

function M.update_pull_request(repo, number, body, opts)
  return gh_json({
    "api",
    string.format("repos/%s/pulls/%d", repo, number),
    "-X",
    "PATCH",
    "-f",
    "body=" .. body,
  }, opts)
end

return M
