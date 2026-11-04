import Foundation
@main struct Test {
 static func main() {
 let ai=CodexAssistant()
 ai.run(text:"#test\n\nhello", instruction:"把标题改成标准 Markdown，只输出修改后的全文。", executable:"") { status,text in
 if status == "done" || status == "error" { print(status + ": " + text); exit(status == "done" ? 0 : 1) }
 }
 RunLoop.main.run()
 }
}
