local util = require("gh_pr_comments.util")

local M = {}

local PULL_REQUEST_BUNDLE_QUERY = [[
query PullRequestBundle(
  $owner: String!
  $name: String!
  $number: Int!
  $includeTimeline: Boolean!
  $timelineCursor: String
  $includeThreads: Boolean!
  $reviewThreadsCursor: String
) {
  viewer {
    login
  }
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number
      title
      body
      url
      viewerCanUpdate
      author {
        login
      }
      timelineItems(
        first: 100
        after: $timelineCursor
        itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW]
      ) @include(if: $includeTimeline) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          __typename
          ... on IssueComment {
            databaseId
            fullDatabaseId
            body
            url
            createdAt
            updatedAt
            viewerCanUpdate
            author {
              login
            }
          }
          ... on PullRequestReview {
            databaseId
            fullDatabaseId
            body
            url
            state
            createdAt
            updatedAt
            submittedAt
            viewerCanUpdate
            author {
              login
            }
          }
        }
      }
      reviewThreads(first: 100, after: $reviewThreadsCursor) @include(if: $includeThreads) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          isOutdated
          isResolved
          viewerCanResolve
          viewerCanUnresolve
          path
          line
          originalLine
          diffSide
          resolvedBy {
            login
          }
          comments(first: 100) {
            pageInfo {
              hasNextPage
              endCursor
            }
            nodes {
              databaseId
              fullDatabaseId
              body
              url
              createdAt
              updatedAt
              viewerCanUpdate
              path
              line
              originalLine
              author {
                login
              }
              replyTo {
                databaseId
                fullDatabaseId
              }
              commit {
                oid
              }
              originalCommit {
                oid
              }
            }
          }
        }
      }
    }
  }
}
]]

local REVIEW_THREAD_COMMENTS_QUERY = [[
query ReviewThreadComments($threadId: ID!, $cursor: String) {
  node(id: $threadId) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $cursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          databaseId
          fullDatabaseId
          body
          url
          createdAt
          updatedAt
          viewerCanUpdate
          path
          line
          originalLine
          author {
            login
          }
          replyTo {
            databaseId
            fullDatabaseId
          }
          commit {
            oid
          }
          originalCommit {
            oid
          }
        }
      }
    }
  }
}
]]

local RESOLVE_REVIEW_THREAD_MUTATION = [[
mutation ResolveReviewThread($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) {
    thread {
      id
      isResolved
    }
  }
}
]]

local UNRESOLVE_REVIEW_THREAD_MUTATION = [[
mutation UnresolveReviewThread($threadId: ID!) {
  unresolveReviewThread(input: { threadId: $threadId }) {
    thread {
      id
      isResolved
    }
  }
}
]]

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

local function add_graphql_variable(args, key, value)
  if value == nil then
    return
  end

  local value_type = type(value)
  if value_type == "boolean" or value_type == "number" then
    vim.list_extend(args, {
      "-F",
      string.format("%s=%s", key, tostring(value)),
    })
    return
  end

  vim.list_extend(args, {
    "-f",
    string.format("%s=%s", key, tostring(value)),
  })
end

local function gh_graphql(query, variables, opts)
  local args = {
    "api",
    "graphql",
    "-f",
    "query=" .. query,
  }

  for key, value in pairs(variables or {}) do
    add_graphql_variable(args, key, value)
  end

  return gh_json(args, opts)
end

local function require_graphql_data(response, context)
  local data = response and response.data
  if type(data) ~= "table" then
    error(string.format("invalid GraphQL response for %s: missing data field", context))
  end
  return data
end

local function split_repo_name(name_with_owner)
  local owner, name = tostring(name_with_owner):match("^([^/]+)/(.+)$")
  if not owner or not name then
    return nil, nil, string.format("invalid repository name %q", tostring(name_with_owner))
  end

  return owner, name, nil
end

local function parse_repo_from_url(url)
  local owner, name = tostring(url):match("^https://github%.com/([^/]+)/([^/]+)/")
  if not owner or not name then
    return nil, nil, string.format("failed to parse repository from URL %q", tostring(url))
  end

  return owner, name, nil
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

function M.current_pull_request_ref(opts)
  local data, err = gh_json({
    "pr",
    "view",
    "--json",
    "number,url",
  }, opts)
  if err then
    return nil, err
  end

  local owner, name, repo_err = parse_repo_from_url(data.url)
  if repo_err then
    return nil, repo_err
  end

  return {
    owner = owner,
    name = name,
    number = data.number,
  }, nil
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

function M.pull_request_bundle(number, opts)
  local ref
  local ref_err

  if number then
    local name_with_owner, repo_err = M.repo_name(opts)
    if repo_err then
      return nil, repo_err
    end

    local owner, name, split_err = split_repo_name(name_with_owner)
    if split_err then
      return nil, split_err
    end

    ref = {
      owner = owner,
      name = name,
      number = number,
    }
  else
    ref, ref_err = M.current_pull_request_ref(opts)
    if ref_err then
      return nil, ref_err
    end
  end

  local bundle = {
    viewer = nil,
    repository_owner = ref.owner,
    repository_name = ref.name,
    pull_request = nil,
    timeline_items = {},
    review_threads = {},
  }

  local timeline_cursor = nil
  local threads_cursor = nil
  local include_timeline = true
  local include_threads = true

  while include_timeline or include_threads do
    local response, err = gh_graphql(PULL_REQUEST_BUNDLE_QUERY, {
      owner = ref.owner,
      name = ref.name,
      number = ref.number,
      includeTimeline = include_timeline,
      timelineCursor = timeline_cursor,
      includeThreads = include_threads,
      reviewThreadsCursor = threads_cursor,
    }, opts)
    if err then
      return nil, err
    end

    local data = require_graphql_data(response, "pull_request_bundle")
    local repository = data.repository
    if repository == nil then
      error("invalid GraphQL response for pull_request_bundle: missing repository")
    end
    local pull_request = repository and repository.pullRequest or nil
    if not pull_request then
      return nil, string.format("pull request #%d was not found", ref.number)
    end

    if type(data.viewer) ~= "table" or type(data.viewer.login) ~= "string" then
      error("invalid GraphQL response for pull_request_bundle: missing viewer.login")
    end

    bundle.viewer = data.viewer
    bundle.pull_request = pull_request

    if include_timeline then
      local timeline = pull_request.timelineItems
      for _, node in ipairs(timeline and timeline.nodes or {}) do
        table.insert(bundle.timeline_items, node)
      end

      include_timeline = timeline and timeline.pageInfo and timeline.pageInfo.hasNextPage or false
      timeline_cursor = timeline and timeline.pageInfo and timeline.pageInfo.endCursor or nil
    end

    if include_threads then
      local review_threads = pull_request.reviewThreads
      for _, node in ipairs(review_threads and review_threads.nodes or {}) do
        table.insert(bundle.review_threads, node)
      end

      include_threads = review_threads and review_threads.pageInfo and review_threads.pageInfo.hasNextPage or false
      threads_cursor = review_threads and review_threads.pageInfo and review_threads.pageInfo.endCursor or nil
    end
  end

  for _, thread in ipairs(bundle.review_threads) do
    local comments = thread.comments or {}
    local page_info = comments.pageInfo or {}
    local end_cursor = page_info.endCursor
    while page_info.hasNextPage do
      local response, err = gh_graphql(REVIEW_THREAD_COMMENTS_QUERY, {
        threadId = thread.id,
        cursor = end_cursor,
      }, opts)
      if err then
        return nil, err
      end

      local data = require_graphql_data(response, "review_thread_comments")
      local node = data.node
      if node == nil then
        error(string.format("invalid GraphQL response for review_thread_comments: missing node for thread %s", tostring(thread.id)))
      end
      if not node.comments then
        error(string.format("invalid GraphQL response for review_thread_comments: missing comments for thread %s", tostring(thread.id)))
      end

      for _, comment in ipairs(node.comments.nodes or {}) do
        table.insert(thread.comments.nodes, comment)
      end

      page_info = node.comments.pageInfo or {}
      end_cursor = page_info.endCursor
      thread.comments.pageInfo = page_info
    end
  end

  return bundle, nil
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

function M.resolve_review_thread(thread_id, opts)
  local response, err = gh_graphql(RESOLVE_REVIEW_THREAD_MUTATION, {
    threadId = thread_id,
  }, opts)
  if err then
    return nil, err
  end

  local data = require_graphql_data(response, "resolve_review_thread")
  if not data.resolveReviewThread or not data.resolveReviewThread.thread then
    error(string.format("invalid GraphQL response for resolve_review_thread: missing thread for %s", tostring(thread_id)))
  end
  return data.resolveReviewThread.thread, nil
end

function M.unresolve_review_thread(thread_id, opts)
  local response, err = gh_graphql(UNRESOLVE_REVIEW_THREAD_MUTATION, {
    threadId = thread_id,
  }, opts)
  if err then
    return nil, err
  end

  local data = require_graphql_data(response, "unresolve_review_thread")
  if not data.unresolveReviewThread or not data.unresolveReviewThread.thread then
    error(string.format("invalid GraphQL response for unresolve_review_thread: missing thread for %s", tostring(thread_id)))
  end
  return data.unresolveReviewThread.thread, nil
end

return M
