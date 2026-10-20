# fanqie.nvim

**在 Neovim 中阅读本地 TXT，查看与正文段落对应的番茄只读段评。**

章节导航 · 段落核验 · 评论与回复 · 本地书签 · 进度恢复 · 离线缓存

> [!NOTE]
> 小说正文始终来自本地文件。联网用于搜索书籍、读取目录、段评与回复，以及段评所需的设备注册和签名。
> 插件没有接入小说正文下载、内容密钥获取、账号登录或云端写操作。

<details>
<summary>目录</summary>

- [环境要求](#环境要求)
- [安装](#安装)
- [快速开始](#快速开始)
- [看段评](#看段评)
- [目录与按章阅读](#目录与按章阅读)
- [对齐规则](#对齐规则)
- [命令](#命令)
- [配置和存储](#配置和存储)
- [验证](#验证)

</details>

## 环境要求

| 项目 | 要求 |
| :--- | :--- |
| Neovim | **≥0.10.0**，使用 LuaJIT 构建 |
| `curl` | 可通过 `PATH` 调用，或在配置中指定可执行文件路径 |
| 本地文件 | UTF-8 编码的 TXT |
| Git | 通过插件管理器从仓库安装时需要 |

## 安装

选择一种安装方式，展开对应示例：

<details>
<summary><strong>lazy.nvim</strong></summary>

将以下配置加入插件列表：

```lua
{
  "lihaoze123/fanqie.nvim",
  main = "fanqie",
  cmd = "Fanqie",
  opts = {},
}
```

</details>

<details>
<summary><strong>vim.pack</strong> · Neovim ≥0.12</summary>

使用 Neovim 内置的 [vim.pack](https://neovim.io/doc/user/pack/#vim.pack)，在 `init.lua` 中添加：

```lua
vim.pack.add({
  { src = "https://github.com/lihaoze123/fanqie.nvim" },
})

require("fanqie").setup({})
```

启动 Neovim 时按提示确认安装。初始化代码放在 `vim.pack.add()` 之后。

</details>

<details>
<summary><strong>vim-plug</strong></summary>

安装 [vim-plug](https://github.com/junegunn/vim-plug) 后，在 `init.vim` 中添加：

```vim
call plug#begin()
Plug 'lihaoze123/fanqie.nvim'
call plug#end()

lua << EOF
local ok, fanqie = pcall(require, "fanqie")
if ok then
  fanqie.setup({})
end
EOF
```

如果已有 `plug#begin()` / `plug#end()` 区块，只需在其中添加 `Plug` 声明，并将 Lua 初始化放在 `plug#end()` 之后。`pcall` 允许首次安装前正常启动。

执行 `:PlugInstall`，安装完成后重启 Neovim。

</details>

<details>
<summary><strong>本地开发</strong> · lazy.nvim 的 dir 配置</summary>

尚未发布到远程仓库时，可通过 `dir` 加载本地源码。将示例路径替换为插件所在目录：

```lua
{
  dir = vim.fn.expand("~/path/to/fanqie.nvim"),
  name = "fanqie.nvim",
  main = "fanqie",
  cmd = "Fanqie",
  opts = {},
}
```

使用其他插件管理器时，在插件加入 `runtimepath` 后调用：

```lua
require("fanqie").setup({})
```

</details>

## 快速开始

1. 用 Neovim 打开本地 TXT 文件。
2. 执行 `:Fanqie enable`，启用当前文件的阅读辅助。
3. 执行 `:Fanqie bind`，输入书名并确认匹配的书籍和作者。
4. 按 `<leader>ft` 打开目录，选中章节后按 `Enter` 开始阅读。
5. 将光标移到正文段落，按 `<leader>fc` 查看段评。

对应命令：

```vim
:Fanqie enable
:Fanqie bind
:Fanqie toc
```

绑定后自动匹配当前章节，读取本章段评统计，并用最多三个评论页探测文本锚点。绑定结果和校准会保存。重新打开文件后执行 `:Fanqie enable` 即可恢复。

> [!TIP]
> `<leader>` 使用 Neovim 的 `mapleader` 配置，默认是反斜杠。
> 若希望使用逗号，请在插件加载前设置：

```lua
vim.g.mapleader = ","
```

### 独立体验（可选）

在插件根目录执行以下命令，将 `/path/to/book.txt` 替换为自己的 TXT 路径：

```sh
nvim -u examples/minimal.lua /path/to/book.txt
```

此配置将 `<leader>` 设为逗号，并在启动时启用当前文件的阅读辅助。首次仍需 `:Fanqie bind`。

## 看段评

已核验的段落末尾显示 `💬 数量`。将光标移到该段，执行 `:Fanqie comments` 或按 `<leader>fc`，即可在右侧窗口查看评论。

当前段落尚未定位时，同一命令会尝试一个候选段号；候选只用于请求，必须经返回原文核验才显示为当前段评论。核验失败则保留未对齐列表。

### 段评窗口快捷键

| 按键 | 操作 |
| :--- | :--- |
| <kbd>n</kbd> / <kbd>p</kbd> | 下一页 / 上一页评论 |
| <kbd>s</kbd> | 切换热门 / 最新排序 |
| <kbd>Enter</kbd> | 展开 / 收起回复，或加载选中的未对齐段评；更多回复有单独条目 |
| <kbd>u</kbd> | 查看未对齐段评列表 |
| <kbd>a</kbd> | 将当前段评绑定到**正文窗口光标所在的段落**，确认后保存 |
| <kbd>o</kbd> | 在图片链接行，用系统浏览器打开图片 |
| <kbd>r</kbd> | 刷新当前段评 |
| <kbd>q</kbd> | 关闭段评窗口 |

加载未对齐段评后，若返回原文能唯一匹配本地段落，会自动补上标记。手动绑定的标记带有 `[手动]`。图片仅显示为链接，不会自动下载。

> [!IMPORTANT]
> **未显示标记不等于零评论。** 自动探测只核验少量段落，初次并非每个有段评的段落都有标记。
> 所有尚未定位的段号都保留在未对齐列表中。

## 目录与按章阅读

按 `<leader>ft`（独立配置中为 `,ft`）打开插件自带的分页目录，默认选中当前章节：

| 按键 | 操作 |
| :--- | :--- |
| <kbd>j</kbd> / <kbd>k</kbd> 或 <kbd>↓</kbd> / <kbd>↑</kbd> | 选择章节 |
| <kbd>Enter</kbd> | 跳到所选章节正文，并关闭目录 |
| <kbd>n</kbd> / <kbd>p</kbd> | 下一页 / 上一页目录 |
| <kbd>PageDown</kbd> / <kbd>PageUp</kbd> 或 <kbd>Ctrl</kbd>+<kbd>f</kbd> / <kbd>Ctrl</kbd>+<kbd>b</kbd> | 下一页 / 上一页目录 |
| <kbd>Space</kbd> | 下一页目录 |
| <kbd>/</kbd> | 搜索全部章节的标题或章号 |
| <kbd>c</kbd> | 清除搜索 |
| <kbd>g</kbd> | 定位当前章节 |
| <kbd>g</kbd><kbd>g</kbd> / <kbd>G</kbd> | 第一项 / 最后一项 |
| <kbd>q</kbd> / <kbd>Esc</kbd> | 关闭目录，回到原窗口 |

进入正文后，`Ctrl-f/Ctrl-b` 按屏翻页；`<leader>fn` 到下一章，`<leader>fp` 到上一章。

## 对齐规则

平台段评使用 `book_id`、章节 `item_id`、段号 `para_index`。TXT 的行号不等于平台段号。插件不获取平台小说正文来对齐，而是利用评论返回的 `para_src_content`：

1. 规范化 HTML 实体、标签、空白；完整原文唯一匹配时定位。
2. 长引用唯一匹配且覆盖至少 80% 本地段落时也可定位。
3. 重复段落、缺少引用、引用不匹配，保持未对齐；支持手动校准。
4. 每个校准记录绑定段落文本哈希；文件改变后重新核验。不会把单个锚点的偏移自动推广到整章。

章节按规范化章号和标题匹配，支持阿拉伯数字、中文数字、无“第”的标题和引子。标题不确定时用 `:Fanqie chapter` 选择。一个本地段落对应多个远端段号时，也不会自动挂上有歧义的标记。

默认每个非空物理行是一段。段落内部有硬换行的文件可设置 `paragraph_mode = "blank"`，按空行分段。`chapter_pattern` 可设置 Vim 正则，第一个捕获组为章号、第二个为标题，例如 `[[\v^([0-9]+)\.\s*(.+)$]]`。

## 命令

| 命令 | 作用 |
| :--- | :--- |
| `:Fanqie enable` / `:Fanqie disable` | 启用 / 关闭当前文件阅读辅助 |
| `:Fanqie bind [书名]` | 搜索并确认书籍和作者 |
| `:Fanqie chapter` | 手动绑定当前章节 |
| `:Fanqie comments` | 当前段落评论；未定位时打开未对齐列表 |
| `:Fanqie unmatched` | 未对齐段评列表 |
| `:Fanqie calibrate [段号]` | 将远端段号绑定到正文光标所在段落 |
| `:Fanqie uncalibrate` | 清除当前段落校准 |
| `:Fanqie toc` | 打开章节目录 |
| `:Fanqie next` / `:Fanqie prev` | 下一章 / 上一章 |
| `:Fanqie bookmark` | 添加本地书签 |
| `:Fanqie bookmarks` / `:Fanqie unbookmark` | 跳转 / 删除本地书签 |
| `:Fanqie refresh` | 强制刷新本章段评统计 |
| `:Fanqie offline` / `:Fanqie online` | 切换当前会话的全局离线 / 在线状态 |
| `:Fanqie status` | 书籍、当前章节、已核验数量与错误 |

### 正文快捷键

| 默认映射 | 操作 |
| :--- | :--- |
| `<leader>fc` | 查看当前段评 |
| `<leader>fu` | 查看未对齐段评 |
| `<leader>ft` | 打开章节目录 |
| `<leader>fn` / `<leader>fp` | 下一章 / 上一章 |
| `<leader>fm` | 添加本地书签 |
| `<leader>fb` | 打开书签列表 |

这些映射仅在启用阅读辅助的正文 buffer 中生效。已有快捷键会保留；设 `keymaps = false` 可关闭默认映射。

## 配置和存储

```lua
require("fanqie").setup({
  panel_width = 52,
  paragraph_mode = "line", -- line / blank
  probe_limit = 3,         -- 每次进入章节最多自动核验的评论页数
  request_interval_ms = 650,
  cache_ttl = 3600,        -- 评论页缓存秒数
  offline = false,
  restore_position = true,
  keymaps = true,
  curl = "curl",
})
```

### 数据位置

| 目录 | 内容 |
| :--- | :--- |
| `stdpath("state")/fanqie/` | 每个文件独立的绑定、校准、书签、阅读位置；`device.json` 保存本机设备身份 |
| `stdpath("cache")/fanqie/` | 按接口、书籍、章节、段号、排序、游标隔离的评论与目录缓存 |

状态文件使用 JSON 原子替换，文件权限为 `0600`。

### 缓存与会话行为

- 进入已绑定章节先显示统计缓存，再后台刷新；评论列表按需请求。退出、切章、关闭插件会取消对应任务。
- 网络、签名和 JSON 处理在隔离的 headless Neovim 进程中执行；正文编辑窗口不会等待网络。
- 离线模式只使用已有缓存。请求失败会显示错误，不把错误当“零评论”写入缓存。
- 不写入或重排原 TXT，不设置全局阅读按键，不自动处理其他文件。阅读时只对当前窗口启用折行。

## 验证

在插件目录执行：

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua
nvim --headless -u NONE -i NONE -l tests/async.lua
nvim --headless -u NONE -i NONE -l tests/toc.lua
```

包括 MD5 标准向量、章节解析/匹配、重复段落拒绝匹配、段落文本核验、回复环处理、界面、书签与持久化；验证 TXT 文件不被修改。

本项目移植来源和模块改动见 [NOTICE.md](NOTICE.md)。
