import Cocoa
import WebKit
import UniformTypeIdentifiers
import PDFKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let store = DraftStore(directory: ProcessInfo.processInfo.environment["MOYE_TEST_DATA_DIR"].map { URL(fileURLWithPath:$0, isDirectory:true) })
    let assistant = CodexAssistant()
    var assistantWindow: NSWindow?
    var assistantWeb: WKWebView?
    var editorFrameBeforeAssistant: NSRect?
    var assistantTheme = "light"
    var snapshot: [String: Any] = [:]
    var closing = false
    var allowClose = false
    var nasBusy = false
    var webReady = false
    var pendingOpenURLs: [URL] = []
    var deletedIDs = Set<String>()
    var closeAcknowledged: [String: String] = [:]
    let titlebarDragView = TitlebarDragView()
    var window: NSWindow!
    var web: WKWebView!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if ProcessInfo.processInfo.environment["MOYE_TEST_DATA_DIR"] == nil,
           NSRunningApplication.runningApplications(withBundleIdentifier: "com.neil.moye").contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            let alert = NSAlert(); alert.messageText = "请先退出已运行的墨页"
            alert.informativeText = "为保护草稿，请退出其他版本后再启动此版本。"
            alert.addButton(withTitle: "退出"); alert.runModal(); NSApp.terminate(nil); return
        }
        do { try store.backupBeforeUpgrade(version: "2.0.2") }
        catch {
            let alert = NSAlert(); alert.messageText = "升级前备份失败"
            alert.informativeText = "为保留回滚数据，墨页尚未修改草稿。请检查磁盘空间和权限后重试。\n" + error.localizedDescription
            alert.addButton(withTitle: "退出"); alert.runModal(); NSApp.terminate(nil); return
        }
        snapshot = store.load() ?? [:]
        let config = WKWebViewConfiguration()
        if ProcessInfo.processInfo.environment["MOYE_TEST_DATA_DIR"] != nil { config.websiteDataStore = .nonPersistent() }
        let bootstrap: [String: Any] = ["snapshot": snapshot, "nas": configJSON(), "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency]
        if let data = try? JSONSerialization.data(withJSONObject: bootstrap), let json = String(data: data, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: "window.moyeBootstrap = " + json, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController.add(self, name: "native")
        let root = Bundle.main.resourceURL!.appendingPathComponent("web")
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 850), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "墨页"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 860, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        window.contentView = effect
        web.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(web)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: effect.leadingAnchor), web.trailingAnchor.constraint(equalTo: effect.trailingAnchor), web.topAnchor.constraint(equalTo: effect.topAnchor), web.bottomAnchor.constraint(equalTo: effect.bottomAnchor)])
        titlebarDragView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(titlebarDragView)
        NSLayoutConstraint.activate([titlebarDragView.leadingAnchor.constraint(equalTo:effect.leadingAnchor), titlebarDragView.trailingAnchor.constraint(equalTo:effect.trailingAnchor), titlebarDragView.topAnchor.constraint(equalTo:effect.topAnchor), titlebarDragView.bottomAnchor.constraint(equalTo:effect.bottomAnchor)])
        makeMenus()
        web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    func showAssistant() {
        if assistantWindow == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(self, name:"native")
            let content = WKWebView(frame:.zero, configuration:configuration)
            content.navigationDelegate = self
            let panel = NSWindow(contentRect:NSRect(x:0,y:0,width:440,height:780), styleMask:[.titled,.closable,.resizable,.miniaturizable], backing:.buffered,defer:false)
            panel.title = "墨页 · 文稿助手"; panel.minSize = NSSize(width:380,height:560)
            panel.isReleasedWhenClosed = false; panel.delegate = self; panel.contentView = content
            assistantWeb = content; assistantWindow = panel
            let root = Bundle.main.resourceURL!.appendingPathComponent("web")
            content.loadFileURL(root.appendingPathComponent("assistant.html"),allowingReadAccessTo:root)
        }
        guard let panel = assistantWindow else { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        if editorFrameBeforeAssistant == nil { editorFrameBeforeAssistant = window.frame }
        if screen.width >= window.minSize.width + panel.frame.width + 10 {
            var editorFrame = window.frame
            editorFrame.size.width = min(editorFrame.width, screen.width-panel.frame.width-10)
            editorFrame.origin.x = max(screen.minX,min(editorFrame.minX,screen.maxX-editorFrame.width-panel.frame.width-10))
            window.setFrame(editorFrame,display:true,animate:false)
        }
        let right = window.frame.maxX + 10
        let x = right + panel.frame.width <= screen.maxX ? right : max(screen.minX, screen.maxX-panel.frame.width)
        panel.setFrameOrigin(NSPoint(x:x,y:max(screen.minY,min(window.frame.maxY-panel.frame.height,screen.maxY-panel.frame.height))))
        panel.makeKeyAndOrderFront(nil)
    }
    func attachReferences() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText,.pdf,UTType(filenameExtension:"docx") ?? .data,UTType(filenameExtension:"md") ?? .plainText]
        panel.beginSheetModal(for:assistantWindow ?? window) { response in
            guard response == .OK else { return }
            var files: [[String:String]] = []
            for url in panel.urls.prefix(8) {
                do {
                    let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                    guard size <= 5_000_000 else { throw DAVError.message("单份参考文件需小于 5 MB。") }
                    let text: String
                    switch url.pathExtension.lowercased() {
                    case "pdf": text = PDFDocument(url:url)?.string ?? ""
                    case "docx": text = try NSAttributedString(url:url,options:[.documentType:NSAttributedString.DocumentType.officeOpenXML],documentAttributes:nil).string
                    default: text = try String(contentsOf:url,encoding:.utf8)
                    }
                    guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw DAVError.message("未提取到正文，扫描 PDF 请先进行 OCR。") }
                    guard text.utf8.count <= 100_000 else { throw DAVError.message("提取正文超过 100 KB，请拆分文件。") }
                    files.append(["id":UUID().uuidString,"name":url.lastPathComponent,"text":text])
                } catch { self.send(["action":"aiAttachmentError","text":url.lastPathComponent + "：" + error.localizedDescription]) }
            }
            self.send(["action":"aiAttachments","files":files])
        }
    }
    func makeMenus() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于墨页", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏墨页", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出墨页", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        let file = NSMenu(title: "文件")
        add(file, "新建文稿", "n", "new")
        add(file, "打开…", "o", "open")
        add(file, "从 NAS 打开…", "O", "nasOpen")
        add(file, "恢复已删除草稿…", "", "restoreDeleted")
        file.addItem(.separator())
        add(file, "保存", "s", "save")
        add(file, "另存为…", "S", "saveAs")
        add(file, "导出 HTML…", "", "exportHTML")
        add(file, "打印…", "p", "print")
        file.addItem(.separator())
        file.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: ""); fileItem.submenu = file; menu.addItem(fileItem)
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", Selector(("undo:")), "z"), ("重做", Selector(("redo:")), "Z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        edit.addItem(.separator()); add(edit, "查找与替换", "f", "find")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editItem.submenu = edit; menu.addItem(editItem)
        let view = NSMenu(title: "显示"); add(view, "切换专注模式", "F", "focus"); add(view, "一键极简 / 恢复界面", "M", "minimal")
        view.addItem(withTitle: "进入全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        let viewItem = NSMenuItem(title: "显示", action: nil, keyEquivalent: ""); viewItem.submenu = view; menu.addItem(viewItem)
        NSApp.mainMenu = menu
    }
    func add(_ menu: NSMenu, _ title: String, _ key: String, _ command: String) {
        let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: key.lowercased())
        if key != key.lowercased() { item.keyEquivalentModifierMask = [.command, .shift] }
        item.target = self; item.representedObject = command; menu.addItem(item)
    }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "墨页 Moye", .applicationVersion: "2.0.2", .credits: NSAttributedString(string: "一处安静的 Markdown 书写空间。\n基于 CodeMirror 6、Marked 与 DOMPurify。")])
    }
    @objc func menuCommand(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String {
            if command == "restoreDeleted" { restoreDeleted(); return }; if ["new", "open", "nasOpen"].contains(command) { window.makeKeyAndOrderFront(nil) }; web.evaluateJavaScript("window.nativeCommand('\(command)')", completionHandler: nil) }
    }
    func send(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.receiveNative(\(json))", completionHandler: nil)
        if (value["action"] as? String)?.hasPrefix("ai") == true { assistantWeb?.evaluateJavaScript("window.receiveAssistant(\(json))", completionHandler:nil) }
    }
    func openLocalURL(_ url: URL) {
        Task { @MainActor in
            do {
                let text = try await Task.detached { try LocalFileIO.read(url) }.value
                send(["action": "opened", "name": url.lastPathComponent, "path": url.path, "text": text, "savedText": text])
            } catch { send(["action": "error", "message": "无法读取文件：" + error.localizedDescription]) }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let data = message.body as? [String: Any], let action = data["action"] as? String else { return }
        switch action {
        case "aiShow": showAssistant()
        case "aiHide": assistantWindow?.orderOut(nil)
        case "aiBegin":
            UserDefaults.standard.set(data["model"] as? String ?? "",forKey:"moye.ai.model")
            UserDefaults.standard.set(data["executable"] as? String ?? "",forKey:"moye.ai.executable")
            if let encoded = try? JSONSerialization.data(withJSONObject:data), let json = String(data:encoded,encoding:.utf8) { web.evaluateJavaScript("window.beginAssistant(\(json))",completionHandler:nil) }
        case "aiApply": web.evaluateJavaScript("document.querySelector('#ai-apply').click()",completionHandler:nil)
        case "aiUI": send(data)
        case "aiAttach": attachReferences()
        case "aiCancel": assistant.cancel()
        case "aiRequest":
            guard let text = data["text"] as? String, let instruction = data["instruction"] as? String, let requestID = data["requestID"] as? String else { return }
            assistant.run(text: text, instruction: instruction, executable: data["executable"] as? String ?? "", model:data["model"] as? String ?? "", references:data["references"] as? String ?? "") { [weak self] status, result in
                self?.send(["action":"aiResult", "requestID":requestID, "status":status, "text":result])
            }
        case "titlebarRegions":
            func rectangles(_ key: String) -> [NSRect] {
                (data[key] as? [[String: Double]] ?? []).compactMap { rect in
                    guard let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"], [x,y,width,height].allSatisfy({ $0.isFinite }), width > 0, height > 0 else { return nil }
                    return NSRect(x:x,y:y,width:width,height:height)
                }
            }
            titlebarDragView.regions = rectangles("regions")
            titlebarDragView.exclusions = rectangles("exclusions")
            titlebarDragView.enabled = data["enabled"] as? Bool ?? false
        case "appearance":
            assistantTheme = data["theme"] as? String ?? "auto"
            send(["action":"aiTheme","theme":assistantTheme])
            switch data["theme"] as? String {
            case "dark": window.appearance = NSAppearance(named: .darkAqua)
            case "light": window.appearance = NSAppearance(named: .aqua)
            default: window.appearance = nil
            }
        case "persist":
            if var value = data["snapshot"] as? [String: Any] {
                value["docs"] = (value["docs"] as? [[String:Any]] ?? []).filter { !deletedIDs.contains($0["id"] as? String ?? "") }
                do { try store.save(value); snapshot = value; send(["action":"persisted"]) }
                catch { send(["action":"error", "message":"本机恢复草稿写入失败，请使用 ⌘S 保存：" + error.localizedDescription]) }
            }
        case "deleteDraft":
            if let doc = data["doc"] as? [String:Any] { do { try deleteDraft(doc) } catch { send(["action":"error", "message":error.localizedDescription]) } }
        case "nasBrowse": browseNAS(data)
        case "nasOpenFile": openNASFile(data)
        case "nasTest", "nasSave": configureNAS(data, save: action == "nasSave")
        case "nasUpload": upload(data)
        case "openRecent":
            if let path = data["path"] as? String { openLocalURL(URL(fileURLWithPath:path)) }
        case "open":
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]; panel.allowsMultipleSelection = false
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                self.openLocalURL(url)
            }
        case "save", "saveAs", "exportHTML":
            guard let text = data["text"] as? String else { return }
            if action == "save", let path = data["path"] as? String { write(text, to: URL(fileURLWithPath: path), id: data["id"] as? String ?? "", notify: true, originalPath: path, expectedText: data["savedText"] as? String); return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = data["name"] as? String ?? "未命名.md"
            panel.allowedContentTypes = [UTType(filenameExtension: action == "exportHTML" ? "html" : "md") ?? .plainText]
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                self.write(text, to: url, id: data["id"] as? String ?? "", notify: action != "exportHTML", originalPath: data["path"] as? String, expectedText: data["savedText"] as? String)
            }
        case "print":
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 40; info.rightMargin = 40
            let operation = web.printOperation(with: info)
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        case "link":
            if let raw = data["url"] as? String, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        default: break
        }
    }
    func deleteDraft(_ doc: [String:Any]) throws {
        guard !nasBusy else { throw DAVError.message("文稿正在上传，请等待上传结束后删除草稿。") }
        guard let id = doc["id"] as? String else { return }
        try store.archive(doc)
        var next = snapshot
        next["docs"] = (snapshot["docs"] as? [[String:Any]] ?? []).filter { $0["id"] as? String != id }
        try store.save(next)
        snapshot = next; deletedIDs.insert(id)
        send(["action":"draftDeleted", "id":id])
    }
    func restoreDeleted() {
        let folder = store.directory.appendingPathComponent("Deleted Drafts", isDirectory:true)
        guard FileManager.default.fileExists(atPath:folder.path) else { send(["action":"error", "message":"暂无已删除的草稿。"]); return }
        window.makeKeyAndOrderFront(nil)
        let panel = NSOpenPanel(); panel.directoryURL = folder; panel.allowedContentTypes = [.json]
        panel.message = "选择要恢复的草稿。恢复为新文稿，不自动上传或覆盖原文件。"; panel.prompt = "恢复草稿"
        panel.beginSheetModal(for:window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                guard let doc = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any], let text = doc["text"] as? String else { throw DAVError.message("不是有效的草稿备份。") }
                self.send(["action":"opened", "name":doc["name"] as? String ?? "恢复的草稿", "text":text])
            } catch { self.send(["action":"error", "message":"恢复草稿失败：" + error.localizedDescription]) }
        }
    }
    func write(_ text: String, to url: URL, id: String, notify: Bool, originalPath: String? = nil, expectedText: String? = nil, completion: ((Bool) -> Void)? = nil) {
        let samePath = originalPath.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() } ?? false
        do {
            try LocalFileIO.write(text, to: url, protectingOriginal: samePath, expectedText: expectedText)
            if notify {
                updateDocument(id) { $0["path"] = url.path; $0["savedText"] = text; $0["name"] = url.deletingPathExtension().lastPathComponent }
                send(["action": "saved", "id": id, "path": url.path, "name": url.lastPathComponent, "savedText": text])
            } else { send(["action": "error", "message": "HTML 已导出"]) }
            completion?(true)
        } catch LocalFileError.conflict {
            let alert = NSAlert(); alert.messageText = "原文件已变化，已阻止覆盖"
            alert.informativeText = LocalFileError.conflict.localizedDescription
            alert.addButton(withTitle: "另存副本…"); alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { completion?(false); return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-副本." + (url.pathExtension.isEmpty ? "md" : url.pathExtension)
                panel.beginSheetModal(for: self.window) { response in
                    guard response == .OK, let target = panel.url else { completion?(false); return }
                    self.write(text, to: target, id: id, notify: notify, originalPath: originalPath, expectedText: expectedText, completion: completion)
                }
            }
        } catch {
            send(["action": "error", "message": "保存失败：" + error.localizedDescription]); completion?(false)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === assistantWeb {
            send(["action":"aiTheme","theme":assistantTheme]); send(["action":"aiSettings","model":UserDefaults.standard.string(forKey:"moye.ai.model") ?? "","executable":UserDefaults.standard.string(forKey:"moye.ai.executable") ?? ""]); return
        }
        webReady = true
        let queued = pendingOpenURLs; pendingOpenURLs.removeAll()
        for url in queued { openLocalURL(url) }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = "移除草稿"; alert.informativeText = message
        alert.addButton(withTitle: "移除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.request.url?.isFileURL == true { decisionHandler(.allow) } else { decisionHandler(.cancel) }
    }
    @objc func accessibilityChanged() {
        send(["action":"accessibility", "reduceTransparency":NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency])
    }
    func configJSON() -> [String: Any] {
        guard let config = store.loadConfig(), let data = try? JSONEncoder().encode(config), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    func browseNAS(_ data: [String: Any]) {
        let requestID = data["requestID"] as? String ?? ""
        guard let raw = data["config"] as? [String: Any], let encoded = try? JSONSerialization.data(withJSONObject:raw), let config = try? JSONDecoder().decode(NASConfig.self,from:encoded) else { return }
        let password = (data["password"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (store.loadConfig()?.username == config.username && store.loadConfig()?.address == config.address ? NASKeychain.read() : nil)
        guard let password = password, !password.isEmpty else { send(["action":"nasListed","requestID":requestID,"ok":false,"message":"请填写 NAS 密码，或先保存有效配置。"]); return }
        let folder = data["folder"] as? String ?? ""
        Task { @MainActor in
            do {
                let contents = try await WebDAVClient(config:config,password:password).listContents(folder:folder)
                let folders = try JSONSerialization.jsonObject(with:try JSONEncoder().encode(contents.folders))
                let files = try JSONSerialization.jsonObject(with:try JSONEncoder().encode(contents.files))
                send(["action":"nasListed","requestID":requestID,"ok":true,"folder":folder,"folders":folders,"files":files])
            } catch { send(["action":"nasListed","requestID":requestID,"ok":false,"message":error.localizedDescription]) }
        }
    }
    func openNASFile(_ data: [String: Any]) {
        let requestID = data["requestID"] as? String ?? ""
        guard let raw = data["config"] as? [String: Any], let encoded = try? JSONSerialization.data(withJSONObject:raw), let config = try? JSONDecoder().decode(NASConfig.self,from:encoded) else { return }
        let saved = store.loadConfig()
        let password = (data["password"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (saved?.username == config.username && saved?.address == config.address ? NASKeychain.read() : nil)
        guard let password = password, !password.isEmpty else { send(["action":"nasOpened","requestID":requestID,"ok":false,"message":"请填写 NAS 密码，或先保存有效配置。"]); return }
        guard let path = data["path"] as? String, !path.isEmpty else { return }
        let fingerprint = (saved?.username == config.username && saved?.address == config.address ? saved?.fingerprint : nil) ?? config.fingerprint
        Task { @MainActor in
            do {
                let result = try await WebDAVClient(config:config,password:password).download(path:path)
                var remote: [String: Any] = ["name":result.name, "folder":result.folder, "path":path, "fingerprint":fingerprint, "text":result.text]
                if let etag = result.etag { remote["etag"] = etag }
                send(["action":"nasOpened","requestID":requestID,"ok":true,"name":result.name,"text":result.text,"remote":remote])
            } catch { send(["action":"nasOpened","requestID":requestID,"ok":false,"message":error.localizedDescription]) }
        }
    }
    func configureNAS(_ data: [String: Any], save: Bool) {
        guard let raw = data["config"] as? [String: Any], let encoded = try? JSONSerialization.data(withJSONObject: raw), let config = try? JSONDecoder().decode(NASConfig.self, from: encoded) else { return }
        let password = (data["password"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (store.loadConfig()?.username == config.username && store.loadConfig()?.address == config.address ? NASKeychain.read() : nil)
        guard let password = password, !password.isEmpty else { send(["action":"nasConfigResult", "ok":false, "message":"请填写 NAS 密码。"]); return }
        Task { @MainActor in
            do {
                try await WebDAVClient(config: config, password: password).test()
                if save { try NASKeychain.save(password); try store.saveConfig(config) }
                send(["action":"nasConfigResult", "ok":true, "saved":save, "config":save ? configJSON() : [:], "message":save ? "NAS 配置已保存" : "目录连接成功；上传时将检查写入权限"])
            } catch { send(["action":"nasConfigResult", "ok":false, "message":error.localizedDescription]) }
        }
    }
    func updateDocument(_ id: String, change: (inout [String: Any]) -> Void) {
        guard var docs = snapshot["docs"] as? [[String: Any]], let index = docs.firstIndex(where: { $0["id"] as? String == id }) else { return }
        change(&docs[index]); snapshot["docs"] = docs
        do { try store.save(snapshot) } catch { send(["action":"error", "message":"本机草稿写入失败，请保存到文件。 "]) }
    }
    func upload(_ data: [String: Any], completion: ((Bool) -> Void)? = nil) {
        let id = data["id"] as? String ?? ""
        guard !deletedIDs.contains(id) else { completion?(false); return }
        guard !nasBusy else { send(["action":"nasFailed", "id":id, "pending":data, "message":"另一份文稿正在上传，稍后自动重试。", "retryable":true]); completion?(false); return }
        guard let config = store.loadConfig(), let password = NASKeychain.read() else { send(["action":"nasFailed", "id":id, "pending":data, "message":"请先在偏好设置中配置 NAS。", "retryable":false]); completion?(false); return }
        guard data["fingerprint"] as? String == config.fingerprint else { send(["action":"nasFailed", "id":id, "pending":data, "message":"NAS 配置已变化，请重新选择上传目标。", "retryable":false]); completion?(false); return }
        guard let text = data["text"] as? String, let name = data["name"] as? String else { completion?(false); return }
        let targetFolder = data["folder"] as? String
        nasBusy = true
        updateDocument(id) { $0["pendingUpload"] = data }
        Task { @MainActor in
            do {
                let etag = try await WebDAVClient(config: config, password: password).upload(name: name, text: text, etag: data["etag"] as? String, updating: data["updating"] as? Bool ?? false, folder: targetFolder)
                let folder = targetFolder ?? config.folder
                let path = (folder.split(separator: "/").map(String.init) + [name]).joined(separator: "/")
                var remote: [String: Any] = ["name":name, "folder":folder, "path":path, "fingerprint":config.fingerprint, "text":text]
                if let etag = etag { remote["etag"] = etag }
                updateDocument(id) { $0["nasRemote"] = remote; $0.removeValue(forKey:"pendingUpload"); $0["nasSavedText"] = text }
                send(["action":"nasUploaded", "id":id, "remote":remote, "savedText":text])
                nasBusy = false; completion?(true)
            } catch {
                let retryable = (error as? DAVError)?.retryable ?? ((error as? URLError).map { [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains($0.code) } ?? false)
                updateDocument(id) { if var pending = $0["pendingUpload"] as? [String: Any] { pending["retryable"] = retryable; pending["message"] = error.localizedDescription; $0["pendingUpload"] = pending } }
                send(["action":"nasFailed", "id":id, "pending":data, "message":error.localizedDescription, "retryable":retryable])
                nasBusy = false; completion?(false)
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === assistantWindow {
            assistantWindow?.orderOut(nil)
            if let frame = editorFrameBeforeAssistant { window.setFrame(frame,display:true); editorFrameBeforeAssistant = nil }
            return false
        }
        if allowClose { assistantWindow?.orderOut(nil); return true }
        beginClose(quitting: false); return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if web == nil { return .terminateNow }
        if closing { return .terminateCancel }
        beginClose(quitting: true); return .terminateLater
    }
    func beginClose(quitting: Bool) {
        guard !closing else { return }; closing = true
        web.evaluateJavaScript("window.exportSnapshot()") { value, error in
            guard let value = value as? [String: Any], error == nil else {
                self.closing = false
                if quitting { NSApp.reply(toApplicationShouldTerminate: false) }
                return
            }
            do { try self.store.save(value); self.snapshot = value }
            catch { self.send(["action":"error", "message":"草稿备份失败，已取消关闭。请先保存到本地文件。"]); self.closing = false; if quitting { NSApp.reply(toApplicationShouldTerminate: false) }; return }
            let docs = (value["docs"] as? [[String: Any]] ?? []).filter { doc in
                ClosePolicy.needsPrompt(doc, acknowledgedText: self.closeAcknowledged[doc["id"] as? String ?? ""])
            }
            self.closeNext(docs, index: 0, quitting: quitting)
        }
    }
    func finishClose(_ success: Bool, quitting: Bool) {
        closing = false
        if quitting { NSApp.reply(toApplicationShouldTerminate: success) }
        else if success { allowClose = true; window.close(); allowClose = false }
    }
    func closeNext(_ docs: [[String: Any]], index: Int, quitting: Bool) {
        guard index < docs.count else { finishClose(true, quitting: quitting); return }
        let doc = docs[index], name = doc["name"] as? String ?? "未命名文稿", id = doc["id"] as? String ?? "", text = doc["text"] as? String ?? ""
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert(); alert.messageText = "保存「\(name)」？"; alert.informativeText = "文稿已备份到本机恢复草稿。你可以现在选择正式保存的位置。"
        alert.addButton(withTitle: doc["path"] == nil ? "保存到本机…" : "保存到原文件")
        let hasNAS = store.loadConfig() != nil
        if hasNAS { alert.addButton(withTitle:"保存到 NAS") }
        alert.addButton(withTitle:"保留草稿并关闭")
        alert.addButton(withTitle:"删除草稿并关闭").hasDestructiveAction = true
        alert.informativeText += " 删除仅移除本机草稿，可从文件菜单恢复；不会删除已保存的本机或 NAS 文件。"
        alert.addButton(withTitle:"取消")
        alert.beginSheetModal(for: window) { response in
            let choice = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let next = { self.closeNext(docs, index:index + 1, quitting:quitting) }
            if choice == 0 {
                let saveAt: (URL) -> Void = { url in
                    self.write(text, to: url, id: id, notify: true, originalPath: doc["path"] as? String, expectedText: doc["savedText"] as? String) { success in
                        if success { next() } else { self.finishClose(false, quitting: quitting) }
                    }
                }
                if let path = doc["path"] as? String { saveAt(URL(fileURLWithPath:path)) }
                else {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = name + ".md"; panel.allowedContentTypes = [UTType(filenameExtension:"md") ?? .plainText]
                    panel.beginSheetModal(for:self.window) { result in
                        if result == .OK, let url = panel.url { saveAt(url) } else { self.finishClose(false, quitting:quitting) }
                    }
                }
            } else if hasNAS && choice == 1 {
                let config = self.store.loadConfig()!
                let remote = doc["nasRemote"] as? [String: Any]
                let same = remote?["fingerprint"] as? String == config.fingerprint
                var data: [String: Any] = ["id":id,"name":same ? remote?["name"] as? String ?? name + ".md" : name + ".md", "text":text,"updating":same,"fingerprint":config.fingerprint]
                if same {
                    data["etag"] = remote?["etag"]
                    if let remoteFolder = remote?["folder"] as? String { data["folder"] = remoteFolder }
                }
                self.upload(data) { success in if success { next() } else { self.finishClose(false, quitting:quitting) } }
            } else if choice == (hasNAS ? 2 : 1) { self.closeAcknowledged[id] = text; next() }
            else if choice == (hasNAS ? 3 : 2) {
                do { try self.deleteDraft(doc); next() }
                catch { self.send(["action":"error", "message":error.localizedDescription]); self.finishClose(false, quitting:quitting) }
            }
            else { self.finishClose(false, quitting:quitting) }
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return }
        if webReady {
            window?.makeKeyAndOrderFront(nil)
            for url in fileURLs { openLocalURL(url) }
        } else {
            pendingOpenURLs.append(contentsOf: fileURLs)
        }
    }
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        application(sender, open: [URL(fileURLWithPath: filename)])
        return true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
