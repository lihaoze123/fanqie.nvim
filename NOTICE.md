# 来源与实现说明

本目录为基于用户提供的 `fanqie.koplugin` 实现的 Neovim 本地 TXT 阅读插件。

`lua/fanqie/protocol/` 中的 `aes.lua`、`sm3.lua`、`text.lua`、`sign.lua`、`device.lua`、`comments.lua` 来自所附插件的 `fanqie/reading/` 同名文件，保留其来源注释。原注释进一步注明源自 `book.koplugin`、`fanqie-re` 和 `kindle-forge`。

移植改动：更换模块命名空间；以独立 MD5 模块替代 KOReader 的 `ffi/sha2`；设备身份使用本插件存储适配器。`crypto.lua` 只摘取随机数、公共查询参数和请求头构造；`transport.lua` 只保留段评使用的签名请求。没有接入正文获取、内容密钥注册和章节解密链路。

Neovim 界面、TXT 解析、文本校准、任务队列、JSON 存储、测试与文档为本次新增实现。

所附源项目 README 的许可证一节标为“MIT License”，同时有单独的用途与分发声明；本地副本没有独立 LICENSE 文件。本说明记录实际来源，不为上游模块另行授予许可。
