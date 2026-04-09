local gh = require("gh_pr_comments.gh")
local target = require("gh_pr_comments.target")
local util = require("gh_pr_comments.util")

local M = {}
local sort_comments

local function object_field(node, key)
  if util.is_nil_like(node) or type(node) ~= "table" then
    return nil
  end

  return node[key]
end

local function normalize_author(author)
  return util.to_string_or_nil(object_field(author, "login")) or "unknown"
end

local function normalize_numeric_id(node)
  return util.to_number_or_nil(object_field(node, "databaseId"))
    or util.to_number_or_nil(object_field(node, "fullDatabaseId"))
    or util.to_number_or_nil(object_field(node, "id"))
end

local function normalize_issue_comment(comment, current_user)
  return {
    kind = "issue_comment",
    id = normalize_numeric_id(comment),
    author = normalize_author(comment.user or comment.author),
    created_at = util.to_string_or_nil(comment.createdAt) or util.to_string_or_nil(comment.created_at),
    updated_at = util.to_string_or_nil(comment.updatedAt) or util.to_string_or_nil(comment.updated_at),
    url = util.to_string_or_nil(comment.url) or util.to_string_or_nil(comment.html_url),
    viewer_can_update = comment.viewerCanUpdate == true or normalize_author(comment.user or comment.author) == current_user,
    body = util.normalize_newlines(comment.body),
  }
end

local function normalize_review(review, current_user)
  local submitted_at = util.to_string_or_nil(review.submittedAt) or util.to_string_or_nil(review.submitted_at) or util.to_string_or_nil(review.createdAt) or util.to_string_or_nil(review.created_at)
  local state = util.to_string_or_nil(review.state) or "COMMENTED"
  local body = util.normalize_newlines(review.body)

  return {
    kind = "review",
    id = normalize_numeric_id(review),
    author = normalize_author(review.user or review.author),
    state = state,
    submitted_at = submitted_at,
    created_at = submitted_at,
    updated_at = util.to_string_or_nil(review.updatedAt) or util.to_string_or_nil(review.updated_at) or submitted_at,
    url = util.to_string_or_nil(review.url) or util.to_string_or_nil(review.html_url),
    viewer_can_update = review.viewerCanUpdate == true or normalize_author(review.user or review.author) == current_user,
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
  local commit_id = util.to_string_or_nil(comment.commit_id)
    or util.to_string_or_nil(comment.original_commit_id)
    or util.to_string_or_nil(object_field(object_field(comment, "commit"), "oid"))
    or util.to_string_or_nil(object_field(object_field(comment, "originalCommit"), "oid"))
  local line = util.to_number_or_nil(comment.line) or util.to_number_or_nil(comment.originalLine) or util.to_number_or_nil(comment.original_line)
  local original_line = util.to_number_or_nil(comment.originalLine) or util.to_number_or_nil(comment.original_line)
  local path = util.to_string_or_nil(comment.path)
  local side = util.to_string_or_nil(comment.side) or util.to_string_or_nil(comment.original_side) or "RIGHT"
  local in_reply_to_id = util.to_number_or_nil(comment.in_reply_to_id)
    or normalize_numeric_id(comment.replyTo)

  return {
    kind = "review_comment",
    id = normalize_numeric_id(comment),
    author = normalize_author(comment.user or comment.author),
    created_at = util.to_string_or_nil(comment.createdAt) or util.to_string_or_nil(comment.created_at),
    updated_at = util.to_string_or_nil(comment.updatedAt) or util.to_string_or_nil(comment.updated_at),
    url = util.to_string_or_nil(comment.url) or util.to_string_or_nil(comment.html_url),
    path = path,
    commit_id = commit_id,
    original_commit_id = util.to_string_or_nil(comment.original_commit_id)
      or util.to_string_or_nil(object_field(object_field(comment, "originalCommit"), "oid")),
    line = line,
    original_line = original_line,
    side = side,
    in_reply_to_id = in_reply_to_id,
    viewer_can_update = comment.viewerCanUpdate == true or normalize_author(comment.user or comment.author) == current_user,
    target = target.build_blob_url(repo, commit_id, path, line or original_line),
    body = util.normalize_newlines(comment.body),
  }
end

local function normalize_review_thread(thread, repo, current_user)
  local comments = {}
  for _, comment in ipairs(thread.comments and thread.comments.nodes or {}) do
    table.insert(comments, normalize_review_comment(comment, repo, current_user))
  end

  table.sort(comments, sort_comments)

  local root_id = nil
  for _, comment in ipairs(comments) do
    if not comment.in_reply_to_id then
      root_id = comment.id
      break
    end
  end

  if not root_id and comments[1] then
    root_id = comments[1].id
  end

  local first = comments[1] or {}

  return {
    id = util.to_string_or_nil(thread.id),
    root_id = root_id,
    path = util.to_string_or_nil(thread.path) or first.path,
    line = util.to_number_or_nil(thread.line) or util.to_number_or_nil(thread.originalLine) or first.line or first.original_line,
    diff_side = util.to_string_or_nil(thread.diffSide) or first.side or "RIGHT",
    is_resolved = thread.isResolved == true,
    resolved_by = normalize_author(thread.resolvedBy),
    viewer_can_resolve = thread.viewerCanResolve == true,
    viewer_can_unresolve = thread.viewerCanUnresolve == true,
    comments = comments,
  }
end

sort_comments = function(a, b)
  if a.created_at == b.created_at then
    return a.id < b.id
  end

  return (a.created_at or "") < (b.created_at or "")
end

function M.load(opts)
  local item
  local item_type
  local view_err

  if opts.number then
    item, view_err = gh.pull_request_bundle(opts.number, opts)
    if item then
      item_type = "pull_request"
    else
      item, view_err = gh.view_issue(opts.number, opts)
      if item then
        item_type = "issue"
      end
    end
  else
    item, view_err = gh.pull_request_bundle(nil, opts)
    if item then
      item_type = "pull_request"
    end
  end

  if not item then
    return nil, view_err or "failed to resolve issue or pull request"
  end

  if item_type == "pull_request" then
    local repo = string.format("%s/%s", item.repository_owner, item.repository_name)

    local current_user = normalize_author(item.viewer)
    local pull_request = item.pull_request
    local comments = {}

    for _, timeline_item in ipairs(item.timeline_items or {}) do
      if timeline_item.__typename == "IssueComment" then
        table.insert(comments, normalize_issue_comment(timeline_item, current_user))
      elseif timeline_item.__typename == "PullRequestReview" and util.to_string_or_nil(timeline_item.state) ~= "PENDING" then
        local normalized = normalize_review(timeline_item, current_user)
        if should_render_review_timeline_item(normalized) then
          table.insert(comments, normalized)
        end
      end
    end

    table.sort(comments, sort_comments)

    local review_threads = {}
    for _, thread in ipairs(item.review_threads or {}) do
      table.insert(review_threads, normalize_review_thread(thread, repo, current_user))
    end

    table.sort(review_threads, function(a, b)
      local left = a.comments[1]
      local right = b.comments[1]
      return sort_comments(left, right)
    end)

    return {
      meta = {
        kind = item_type,
        repo = repo,
        number = pull_request.number,
        title = pull_request.title,
        url = pull_request.url,
        author = normalize_author(pull_request.author),
        current_user = current_user,
        body_viewer_can_update = pull_request.viewerCanUpdate == true or normalize_author(pull_request.author) == current_user,
      },
      body = util.normalize_newlines(pull_request.body),
      timeline_items = comments,
      review_threads = review_threads,
    }, nil
  end

  local repo, repo_err = gh.repo_name(opts)
  if repo_err then
    return nil, repo_err
  end

  local current_user, user_err = gh.current_user(opts)
  if user_err then
    return nil, user_err
  end

  local issue_comments, issue_err = gh.issue_comments(repo, item.number, opts)
  if issue_err then
    return nil, issue_err
  end

  local comments = {}
  for _, comment in ipairs(issue_comments) do
    table.insert(comments, normalize_issue_comment(comment, current_user))
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
