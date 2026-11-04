import Foundation
@main struct NativeTests {
    static func main() async throws {
        precondition(!ClosePolicy.needsPrompt(["text":"  "]))
        precondition(ClosePolicy.needsPrompt(["text":"new draft"]))
        precondition(!ClosePolicy.needsPrompt(["text":"saved", "path":"/sample.md", "savedText":"saved"]))
        precondition(ClosePolicy.needsPrompt(["text":"edited", "path":"/sample.md", "savedText":"saved"]))
        precondition(ClosePolicy.needsPrompt(["text":"", "path":"/sample.md", "savedText":"saved"]))
        precondition(!ClosePolicy.needsPrompt(["text":"cloud", "nasRemote":["name":"a.md"], "nasSavedText":"cloud"]))
        precondition(ClosePolicy.needsPrompt(["text":"cloud", "nasRemote":["name":"a.md"], "nasSavedText":"cloud", "pendingUpload":["name":"a.md"]]))
        precondition(!ClosePolicy.needsPrompt(["text":"draft"], acknowledgedText:"draft"))
        precondition(ClosePolicy.needsPrompt(["text":"changed"], acknowledgedText:"draft"))
        let base = URL(string:"https://example.invalid/dav/")!
        let response = HTTPURLResponse(url:base,statusCode:207,httpVersion:nil,headerFields:nil)!
        let fixture = """
        <multistatus xmlns="DAV:"><response><href>/dav/</href><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response><response><href>/dav/%E4%B8%AD%E6%96%87%20%23/</href><propstat><prop><resourcetype><collection/></resourcetype><displayname>中文 #</displayname></prop><status>HTTP/1.1 200 OK</status></propstat></response><response><href>/davish/outside/</href><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>
        """
        let parsed = try DAVListing.parse(Data(fixture.utf8),response:response,directory:base,base:base)
        precondition(parsed.count == 1 && parsed[0].path == "中文 #")
        do { _ = try DAVListing.parse(Data("<!DOCTYPE test><multistatus xmlns='DAV:'/ >".utf8),response:response,directory:base,base:base); fatalError("DOCTYPE accepted") }
        catch DAVError.message(_) {}
        let address = CommandLine.arguments[1]
        let config = NASConfig(address:address, username:"tester", folder:"文稿", allowHTTP:true)
        let client = WebDAVClient(config:config,password:"test-only")
        try await client.test()
        try await WebDAVClient(config:NASConfig(address:address,username:"tester",folder:"transient",allowHTTP:true),password:"test-only").test()
        let rootContents = try await client.listContents(folder: "")
        precondition(Set(rootContents.folders.map { $0.path }) == Set(["示例文件", "Space Folder"]))
        precondition(rootContents.files.map { $0.path } == ["note.md"])
        let child = try await client.list(folder: "示例文件")
        precondition(child.count == 1 && child[0].path == "示例文件/子 目录")
        let empty = try await client.list(folder:"示例文件/子 目录"); precondition(empty.isEmpty)
        do { _ = try await client.list(folder:"missing"); fatalError("207 self-404 accepted") }
        catch DAVError.status(let code) { precondition(code == 404) }
        do { _ = try await client.list(folder:"notxml"); fatalError("HTML accepted as listing") }
        catch DAVError.message(_) {}

        for path in ["huge.md", "chunked.md"] {
            do { _ = try await client.download(path: path); fatalError("oversized download accepted") }
            catch DAVError.message(let message) { precondition(message.contains("大小限制")) }
        }
        let first = try await client.upload(name:"测试 文稿.md",text:"# 版本一",etag:nil,updating:false)
        precondition(first == "\"v1\"")
        do { _ = try await client.upload(name:"测试 文稿.md",text:"不得覆盖",etag:nil,updating:false); fatalError("new-file collision overwrote remote") }
        catch DAVError.status(let code) { precondition(code == 412) }
        let second = try await client.upload(name:"测试 文稿.md",text:"# 版本二",etag:first,updating:true)
        precondition(second == "\"v2\"")
        let downloaded = try await client.download(path:"文稿/测试 文稿.md")
        precondition(downloaded.text == "# 版本二" && downloaded.etag == "\"v2\"" && downloaded.folder == "文稿" && downloaded.name == "测试 文稿.md")
        do { _ = try await client.download(path:"../secret.md"); fatalError("path traversal allowed") }
        catch DAVError.message(_) {}
        do { _ = try await client.upload(name:"测试 文稿.md",text:"过期版本",etag:first,updating:true); fatalError("stale update overwrote remote") }
        catch DAVError.status(let code) { precondition(code == 412) }
        do { _ = try await client.upload(name:"测试 文稿.md",text:"无 ETag",etag:nil,updating:true); fatalError("missing ETag allowed") }
        catch DAVError.message(_) {}
        do { _ = try NASConfig(address:address,username:"",folder:"",allowHTTP:false).directory(); fatalError("HTTP default allowed") }
        catch DAVError.message(_) {}
        do { try await WebDAVClient(config:config,password:"wrong").test(); fatalError("bad password accepted") }
        catch DAVError.status(let code) { precondition(code == 401) }
        do { _ = try await client.upload(name:"offline.md",text:"本地保留",etag:nil,updating:false); fatalError("503 accepted") }
        catch let error as DAVError { precondition(error.retryable) }
        do { try await WebDAVClient(config:NASConfig(address:address+"/redirect",username:"tester",folder:"",allowHTTP:true),password:"test-only").test(); fatalError("redirect followed") }
        catch DAVError.status(let code) { precondition(code == 302) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DraftStore(directory:temp)
        defer { try? FileManager.default.removeItem(at:temp) }
        try store.archive(["id":"deleted", "name":"删除测试", "text":"可恢复的正文"])
        let deleted = try store.latestDeleted()
        precondition(deleted?["text"] as? String == "可恢复的正文")
        try store.save(["docs":[["id":"one", "text":"first"]]])
        try store.save(["docs":[["id":"one", "text":"second"]]])
        // A redundant save must not rotate away the meaningful previous version.
        try store.save(["docs":[["id":"one", "text":"second"]]])
        precondition((store.load()?["docs"] as? [[String:String]])?.first?["text"] == "second")
        try Data("corrupt".utf8).write(to:store.file)
        precondition((store.load()?["docs"] as? [[String:String]])?.first?["text"] == "first")
        // A valid fallback must survive the first save after a corrupt primary.
        try store.save(["docs":[["id":"one", "text":"recovered"]]])
        try Data("corrupt again".utf8).write(to: store.file)
        precondition((store.load()?["docs"] as? [[String:String]])?.first?["text"] == "first")

        let local = temp.appendingPathComponent("local.md")
        try "baseline".write(to: local, atomically: true, encoding: .utf8)
        try LocalFileIO.write("edited", to: local, protectingOriginal: true, expectedText: "baseline")
        let savedLocal = try LocalFileIO.read(local); precondition(savedLocal == "edited")
        try "external".write(to: local, atomically: true, encoding: .utf8)
        do { try LocalFileIO.write("must not overwrite", to: local, protectingOriginal: true, expectedText: "edited"); fatalError("external changes overwritten") }
        catch LocalFileError.conflict {}
        let externalLocal = try LocalFileIO.read(local); precondition(externalLocal == "external")
        do { try LocalFileIO.write("unknown baseline", to: local, protectingOriginal: true, expectedText: nil); fatalError("unknown baseline overwritten") }
        catch LocalFileError.conflict {}
        try FileManager.default.removeItem(at: local)
        do { try LocalFileIO.write("must not recreate", to: local, protectingOriginal: true, expectedText: "external"); fatalError("deleted file recreated") }
        catch LocalFileError.conflict {}
        precondition(!FileManager.default.fileExists(atPath: local.path))
        try LocalFileIO.write("copy", to: local, protectingOriginal: false, expectedText: nil)
        let largeFile = temp.appendingPathComponent("large.md")
        try Data(repeating: 65, count: LocalFileIO.maxBytes + 1).write(to: largeFile)
        do { _ = try LocalFileIO.read(largeFile); fatalError("oversized local file accepted") }
        catch LocalFileError.tooLarge {}
        try Data([0xff, 0xfe, 0xfd]).write(to: local)
        do { _ = try LocalFileIO.read(local); fatalError("invalid UTF8 accepted") }
        catch LocalFileError.invalidUTF8 {}

        let upgradeRoot = temp.appendingPathComponent("upgrade-test")
        let upgrade = DraftStore(directory: upgradeRoot.appendingPathComponent("v1.1"))
        try upgrade.save(["docs":[["id":"legacy", "text":"old draft"]]])
        try upgrade.saveConfig(NASConfig(address:"https://example.invalid", username:"u", folder:"folder", allowHTTP:false))
        try upgrade.archive(["id":"deleted", "text":"old archive"])
        let backup = try upgrade.backupBeforeUpgrade(version: "1.1.6")!
        let secondBackup = try upgrade.backupBeforeUpgrade(version: "1.1.6"); precondition(secondBackup == nil)
        let frozen = DraftStore(directory: backup)
        try upgrade.save(["docs":[["id":"new", "text":"new draft"]]])
        precondition((frozen.load()?["docs"] as? [[String:String]])?.first?["text"] == "old draft")
        precondition(frozen.loadConfig()?.folder == "folder")
        let archivedBeforeUpgrade = try frozen.latestDeleted(); precondition(archivedBeforeUpgrade?["text"] as? String == "old archive")
        // Rehearse a data rollback into an isolated destination; never touch user data.
        let restoredPath = upgradeRoot.appendingPathComponent("restored-v1.1")
        try FileManager.default.copyItem(at: backup, to: restoredPath)
        precondition((DraftStore(directory:restoredPath).load()?["docs"] as? [[String:String]])?.first?["text"] == "old draft")
        print("PASS: local conflict and size guards; upgrade backup and rollback rehearsal; recovery after corruption; bounded HTTP/chunked downloads; WebDAV directory/auth, encoded filenames, create, conditional update, conflicts, missing ETag, offline retry classification, redirect block; atomic drafts and recovery fallback; close/cancel-save policy and exact-text acknowledgement; namespace-aware directory listing, Unicode/space paths, service subpath, 207 errors, malformed XML and entity rejection")
    }
}
