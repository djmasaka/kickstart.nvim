-- Auto-saved Session.vim for tmux-resurrect.
--
-- tmux-resurrect's `@resurrect-strategy-nvim 'session'` restores a pane with
-- `nvim -S` *only if* a `Session.vim` file exists in that pane's directory.
-- Otherwise it replays the original command line, which is why only the file
-- nvim was launched with came back.
--
-- This module keeps `Session.vim` in the cwd up to date while you work, so an
-- unclean shutdown (crash, power loss) still leaves a full, recent session.

local M = {}

-- Directories where a stray Session.vim would do more harm than good.
local ignored_dirs = {
  [vim.env.HOME] = true,
  ['/'] = true,
  ['/tmp'] = true,
}

-- Filetypes where a session makes no sense (transient, tool-driven buffers).
local ignored_filetypes = {
  gitcommit = true,
  gitrebase = true,
  ['git.commit'] = true,
}

local session_file = function()
  return vim.fn.getcwd() .. '/Session.vim'
end

--- True when the current nvim instance is worth persisting.
local function should_save()
  if vim.g.session_autosave_disabled then
    return false
  end
  if ignored_dirs[vim.fn.getcwd()] then
    return false
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted then
      if ignored_filetypes[vim.bo[buf].filetype] then
        return false
      end
      -- A real, named file buffer is what makes the session meaningful.
      local name = vim.api.nvim_buf_get_name(buf)
      if vim.bo[buf].buftype == '' and name ~= '' and not name:match '://' then
        return true
      end
    end
  end
  return false
end

--- `:mksession` records every listed buffer, including plugin scratch buffers
--- (neo-tree, fugitive, terminals). Those come back as broken empty windows,
--- so drop the `badd` lines that don't point at a real file on disk.
local function strip_phantom_buffers(lines)
  local kept = {}
  for _, line in ipairs(lines) do
    local name = line:match '^badd %+%d+ (.+)$'
    if name and (name:match '://' or vim.fn.filereadable(vim.fn.fnamemodify(name, ':p')) == 0) then
      goto continue
    end
    kept[#kept + 1] = line
    ::continue::
  end
  return kept
end

function M.save()
  if not should_save() then
    return
  end
  local tmp = vim.fn.tempname()
  local ok = pcall(vim.cmd, 'mksession! ' .. vim.fn.fnameescape(tmp))
  if not ok then
    return
  end
  local lines = strip_phantom_buffers(vim.fn.readfile(tmp))
  vim.fn.writefile(lines, session_file())
  vim.fn.delete(tmp)
end

function M.restore()
  local file = session_file()
  if vim.fn.filereadable(file) == 1 then
    vim.cmd('silent! source ' .. vim.fn.fnameescape(file))
  else
    vim.notify('No Session.vim in ' .. vim.fn.getcwd(), vim.log.levels.WARN)
  end
end

function M.delete()
  vim.g.session_autosave_disabled = true
  vim.fn.delete(session_file())
  vim.notify('Session deleted, autosave disabled for this instance', vim.log.levels.INFO)
end

function M.setup()
  -- `buffers` is what carries the full buffer list; `terminal` is dropped
  -- because restored terminal buffers re-run commands in the wrong context.
  vim.opt.sessionoptions = { 'buffers', 'curdir', 'folds', 'help', 'tabpages', 'winsize' }

  -- Debounce: editing fires these constantly, one write per second is plenty.
  local timer = nil
  local function schedule_save()
    if timer then
      timer:stop()
    end
    timer = vim.defer_fn(function()
      timer = nil
      M.save()
    end, 1000)
  end

  local group = vim.api.nvim_create_augroup('custom-session-autosave', { clear = true })

  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'BufDelete', 'TabNew', 'TabClosed', 'VimResized', 'FocusLost' }, {
    group = group,
    callback = schedule_save,
  })

  -- On a clean exit, close plugin windows first so the layout restores cleanly.
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].buftype ~= '' and vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
      M.save()
    end,
  })

  vim.api.nvim_create_user_command('SessionSave', function()
    M.save()
    vim.notify('Saved ' .. session_file(), vim.log.levels.INFO)
  end, { desc = 'Write Session.vim for the current directory' })

  vim.api.nvim_create_user_command('SessionRestore', M.restore, { desc = 'Source Session.vim from the current directory' })
  vim.api.nvim_create_user_command('SessionDelete', M.delete, { desc = 'Delete Session.vim and stop autosaving' })
end

return M
