if vim.g.loaded_gh_pr_comments then
  return
end

vim.g.loaded_gh_pr_comments = 1

vim.api.nvim_create_user_command("GhComment", function(opts)
  require("gh_pr_comments").open({
    number = opts.args ~= "" and tonumber(opts.args) or nil,
  })
end, {
  nargs = "?",
})
