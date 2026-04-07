local M = {}

function M.build_blob_url(repo, commit_id, path, line)
  if not repo or not commit_id or not path or not line then
    return nil
  end

  return string.format("https://github.com/%s/blob/%s/%s#L%d", repo, commit_id, path, line)
end

function M.parse_blob_url(url)
  if type(url) ~= "string" or url == "" then
    return nil, "missing review target URL"
  end

  local repo, commit_id, path, line = url:match("^https://github%.com/([^/]+/[^/]+)/blob/([^/]+)/(.+)#L(%d+)$")
  if not repo then
    local range_repo, range_commit, range_path = url:match("^https://github%.com/([^/]+/[^/]+)/blob/([^/]+)/(.+)#L%d+%-L%d+$")
    if range_repo then
      return nil, "line range URLs are not supported for new review comments"
    end

    return nil, "invalid GitHub blob URL"
  end

  return {
    repo = repo,
    commit_id = commit_id,
    path = path,
    line = tonumber(line),
  }, nil
end

return M
