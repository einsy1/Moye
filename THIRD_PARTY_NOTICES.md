# 第三方组件与引用

墨页采用 MIT 许可证；以下组件的版权和许可由其上游作者保留。具体版本由 [package-lock.json](package-lock.json) 固定。

| 组件 | 用途 | 上游与许可 |
| --- | --- | --- |
| CodeMirror 6 / Lezer | 编辑器、语言解析与高亮 | [CodeMirror](https://codemirror.net/)、[Lezer](https://lezer.codemirror.net/) · MIT |
| Marked | Markdown 解析 | [markedjs/marked](https://github.com/markedjs/marked) · MIT |
| DOMPurify | HTML 内容清理 | [cure53/DOMPurify](https://github.com/cure53/DOMPurify) · Apache-2.0 OR MPL-2.0 |
| Lucide | 界面图标 | [Lucide](https://lucide.dev/license) · ISC，包含其保留的 Feather 衍生图标声明 |
| esbuild | 构建工具 | [evanw/esbuild](https://github.com/evanw/esbuild) · MIT |
| Playwright | 测试和示例截图 | [microsoft/playwright](https://github.com/microsoft/playwright) · Apache-2.0 |

构建脚本会将所有生产依赖随包提供的完整许可证复制到应用 `Contents/Resources/Licenses/`，并生成版本索引；以上摘要不替代完整条款。CodeMirror / Lezer 的传递依赖也在该目录中保留许可。

## 设计参考

项目文档记载功能设计参考 [MarkEdit](https://github.com/MarkEdit-app/MarkEdit)。当前公开源码采用自己的 AppKit / WKWebView 结构。此说明不代表 MarkEdit 对本项目的背书，也不将其商标或标识纳入墨页许可。

## AI 开发工具与服务

作者使用 OpenAI Codex、Google Antigravity 等 AI Agent 辅助开发和迭代。它们是开发工具，不作为墨页运行时依赖捆绑发行。

文稿助手通过用户自行安装的 [Codex CLI](https://github.com/openai/codex) 与 [App Server](https://learn.chatgpt.com/docs/app-server) 接入；Codex 不随本应用捆绑发行，其软件及服务适用各自条款。本项目与 OpenAI、Google 无隶属关系。
