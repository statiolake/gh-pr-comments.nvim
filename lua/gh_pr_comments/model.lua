local gh = require("gh_pr_comments.gh")
local target = require("gh_pr_comments.target")
local util = require("gh_pr_comments.util")

local M = {}

local function normalize_author(author)
  return author and author.login or "unknown"
end

local function normalize_issue_comment(comment, current_user)
  return {
    kind = "issue_comment",
    id = comment.id,
    author = normalize_author(comment.user),
    created_at = comment.created_at,
    updated_at = comment.updated_at,
    url = comment.html_url,
    viewer_can_update = normalize_author(comment.user) == current_user,
    body = util.normalize_newlines(comment.body),
  }
end

local function normalize_review(review, current_user)
  local submitted_at = util.to_string_or_nil(review.submitted_at) or util.to_string_or_nil(review.created_at)
  local state = util.to_string_or_nil(review.state) or "COMMENTED"
  local body = util.normalize_newlines(review.body)

  return {
    kind = "review",
    id = review.id,
    author = normalize_author(review.user),
    state = state,
    submitted_at = submitted_at,
    created_at = submitted_at,
    updated_at = util.to_string_or_nil(review.updated_at) or submitted_at,
    url = review.html_url,
    viewer_can_update = normalize_author(review.user) == current_user,
    body = body,
  }
end

local function should_render_review_timeline_item(review)
  if review.state == "APPROVED" or review.state == "CHANGES_REQUESTED" then
    return true
  end

  if review.state == "COMMENTED" then
    return util.trim(review.body) ~= ""
  end

  return false
end

local function normalize_review_comment(comment, repo, current_user)
  local commit_id = util.to_string_or_nil(comment.commit_id) or util.to_string_or_nil(comment.original_commit_id)
  local line = util.to_number_or_nil(comment.line) or util.to_number_or_nil(comment.original_line)
  local path = util.to_string_or_nil(comment.path)
  local side = util.to_string_or_nil(comment.side) or util.to_string_or_nil(comment.original_side) or "RIGHT"
  local in_reply_to_id = util.to_number_or_nil(comment.in_reply_to_id)

  return {
    kind = "review_comment",
    id = comment.id,
    author = normalize_author(comment.user),
    created_at = comment.created_at,
    updated_at = comment.updated_at,
    url = comment.html_url,
    path = path,
    commit_id = commit_id,
    original_commit_id = util.to_string_or_nil(comment.original_commit_id),
    line = line,
    original_line = util.to_number_or_nil(comment.original_line),
    side = side,
    in_reply_to_id = in_reply_to_id,
    viewer_can_update = normalize_author(comment.user) == current_user,
    target = target.build_blob_url(repo, commit_id, path, line),
    body = util.normalize_newlines(comment.body),
  }
end

local function sort_comments(a, b)
  if a.created_at == b.created_at then
    return a.id < b.id
  end

  return (a.created_at or "") < (b.created_at or "")
end

function M.load(opts)
  local repo, repo_err = gh.repo_name(opts)
  if repo_err then
    return nil, repo_err
  end

  local current_user, user_err = gh.current_user(opts)
  if user_err then
    return nil, user_err
  end

  local item
  local item_type
  local view_err

  if opts.number then
    item, view_err = gh.view_pull_request(opts.number, opts)
    if item then
      item_type = "pull_request"
    else
      item, view_err = gh.view_issue(opts.number, opts)
      if item then
        item_type = "issue"
      end
    end
  else
    item, view_err = gh.view_pull_request(nil, opts)
    if item then
      item_type = "pull_request"
    end
  end

  if not item then
    return nil, view_err or "failed to resolve issue or pull request"
  end

  local issue_comments, issue_err = gh.issue_comments(repo, item.number, opts)
  if issue_err then
    return nil, issue_err
  end

  local comments = {}
  for _, comment in ipairs(issue_comments) do
    table.insert(comments, normalize_issue_comment(comment, current_user))
  end

  if item_type == "pull_request" then
    local reviews, reviews_err = gh.reviews(repo, item.number, opts)
    if reviews_err then
      return nil, reviews_err
    end

    for _, review in ipairs(reviews) do
      if util.to_string_or_nil(review.state) ~= "PENDING" then
        local normalized = normalize_review(review, current_user)
        if should_render_review_timeline_item(normalized) then
          table.insert(comments, normalized)
        end
      end
    end

    table.sort(comments, sort_comments)

    local review_comments, review_err = gh.review_comments(repo, item.number, opts)
    if review_err then
      return nil, review_err
    end

    local threads_by_root = {}
    local roots = {}

    for _, comment in ipairs(review_comments) do
      local normalized = normalize_review_comment(comment, repo, current_user)
      local root_id = normalized.in_reply_to_id or normalized.id
      local thread = threads_by_root[root_id]
      if not thread then
        thread = { root_id = root_id, comments = {} }
        threads_by_root[root_id] = thread
        table.insert(roots, thread)
      end
      table.insert(thread.comments, normalized)
    end

    for _, thread in ipairs(roots) do
      table.sort(thread.comments, sort_comments)
    end

    table.sort(roots, function(a, b)
      local left = a.comments[1]
      local right = b.comments[1]
      return sort_comments(left, right)
    end)

    return {
      meta = {
        kind = item_type,
        repo = repo,
        number = item.number,
        title = item.title,
        url = item.url,
        author = item.author and item.author.login or "unknown",
        current_user = current_user,
        body_viewer_can_update = (item.author and item.author.login or "unknown") == current_user,
      },
      body = util.normalize_newlines(item.body),
      timeline_items = comments,
      review_threads = roots,
    }, nil
  end

  table.sort(comments, sort_comments)

  return {
    meta = {
      kind = item_type,
      repo = repo,
      number = item.number,
      title = item.title,
      url = item.url,
      author = item.author and item.author.login or "unknown",
      current_user = current_user,
      body_viewer_can_update = (item.author and item.author.login or "unknown") == current_user,
    },
    body = util.normalize_newlines(item.body),
    timeline_items = comments,
    review_threads = {},
  }, nil
end

return M
