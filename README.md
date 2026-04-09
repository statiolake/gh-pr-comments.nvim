# gh-pr-comments.nvim

Small Neovim plugin for reading and editing GitHub issue comments and pull request review comments through `gh`.

## Scope

- `:GhComment [number]` opens the current pull request, or the specified pull request or issue, in a markdown-like buffer.
- Saving the buffer parses the edited document and syncs updates through `gh api`.
- Existing items are identified by visible labels such as `@user comment#123` or `@user review#456 [APPROVED]`.
- Pull request and issue bodies are editable from the `## Description` section when the current user is the author.
- Review threads are shown under `## Reviews`.
- Review comments can be exported to quickfix through a Lua API.

This plugin is intentionally small. It does not try to provide a full review UI, diff viewer, extmarks, or conceal-based decoration.

## Requirements

- Neovim with `vim.system` and `vim.json`
- Authenticated `gh` CLI

## Installation

With `lazy.nvim`:

```lua
require("lazy").setup({
  {
    "statiolake/gh-pr-comments.nvim",
  },
})
```

For local development:

```lua
require("lazy").setup({
  {
    dir = "/absolute/path/to/gh-pr-comments.nvim",
    name = "gh-pr-comments.nvim",
  },
})
```

## Usage

Open the current pull request:

```vim
:GhComment
```

Open a specific issue or pull request:

```vim
:GhComment 123
```

The rendered document uses this structure:

- `## Description`: issue or pull request body
- `## Comments`: top-level timeline comments
- `## Reviews`: file/line review threads
- Rendered review thread headings use `path:line` so they work well with `gf`.
- Existing review thread headings also include `thread#...`; adding or removing `[RESOLVED]` on that heading toggles the thread state on save.
- Fold markers are emitted as HTML comments, so the rendered buffer stays valid Markdown.

Bodies may be written either as plain text or as fenced blocks. After a successful save, the buffer is re-rendered into the canonical fenced form.

Example:

````markdown
# Pull Request #123: Example

## Description

```comment
Body text
```

## Comments

@user comment#123
```comment
Existing issue comment
```

---

```comment
New top-level comment
```

## Reviews

### path/to/file.ts:10 thread#PRRT_example [RESOLVED]

@reviewer comment#456
```comment
Existing review comment
```

---

Plain-text reply without an explicit fence
````

## Save Behavior

- Parse errors stop sync immediately.
- Non-editable existing items are skipped and restored on re-render.
- Other API errors are reported and the failed edited text is kept in the re-rendered buffer.
- Updated IDs, skipped IDs, and failed IDs are reported with `vim.notify()`.

## Supported Edits

- Edit the issue or pull request body
- Edit an existing issue comment
- Edit an existing review comment that belongs to the current user
- Add a new top-level timeline comment under `## Comments`
- Add a new review thread by appending a `### https://github.com/...` heading and body under `## Reviews`
- Add a new reply inside an existing review thread, with or without an `@name` line

## Quickfix API

```lua
local items = require("gh_pr_comments").review_comment_qf_items({
  number = 123,
})

vim.fn.setqflist({}, " ", {
  title = "PR review comments",
  items = items,
})

vim.cmd.copen()
```
