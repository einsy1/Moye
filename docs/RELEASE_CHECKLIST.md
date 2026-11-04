# v2.0.1 公开发行检查

检查日期：2026-11-04（Asia/Shanghai）。范围仅为 Moye-public 公开源码快照和由其构建的发行包。

## 已完成

- package.json、锁文件、应用版本与 Codex 客户端版本均为 2.0.1。
- 独立 Git 仓库；初始快照仅纳入项目文件，不导入上级目录和私人历史。
- README、浅深色编辑截图与助手演示截图、下载 / 构建 / 使用说明。
- MIT 许可、上游项目引用与 AI 辅助开发说明。
- 生产依赖完整许可证与版本索引随应用发行；缺失许可会中止构建。
- 隐私、安全反馈、贡献、问题模板、PR 模板及回滚说明。
- npm ci 完成；依赖安装审计为 0 vulnerabilities。
- 本地构建成功；codesign --verify --deep --strict 通过（ad-hoc 签名）。
- 编辑器冒烟、Markdown、原生消息桥、回归、助手界面、原生存储 / WebDAV、标题栏测试共七组通过。
- 发布源码使用 Gitleaks 默认规则扫描；另人工检查域名、地址、凭据字段、绝对路径及文稿示例。未发现真实凭据或个人文稿。

## 发布边界

- 不发布 node_modules、dist、工作区、NAS 配置、钥匙串、登录文件、日志和私人开发记录。
- 测试中的 test-only / test-password 等值为本地模拟服务的构造凭据；不是生产凭据。
- `com.neil.moye` 为兼容旧版存储和钥匙串的固定产品标识，保留不改。
- SHA256SUMS 使用下载文件名，不依赖开发机目录。
- 真实 Codex 生成测试不在本轮执行；助手截图使用演示回调。
- 尚未完成 Apple Developer ID 签名、公证、Intel、全部 macOS 版本与真实 NAS 验收。
- 自动扫描不能证明不存在未知风险；后续按 SECURITY.md 反馈并处理。

## 本地环境

Apple Silicon；Node.js 26.9.0；Apple Swift 6.4.2。GitHub Actions 配置使用 Node.js 22 与 macos-14；CI 结果以仓库 Actions 实际运行结果为准。

## 本次额外核查

GitHub 的敏感信息扫描包含 Git 历史，因此采用独立初始快照，并在首次上传前检查该历史。参考 [GitHub Secret scanning](https://docs.github.com/en/code-security/concepts/secret-security/secret-scanning)。
