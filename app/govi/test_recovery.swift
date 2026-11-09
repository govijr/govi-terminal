import Foundation

@main struct RecoveryScriptFixture {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let input = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        print(
            GoviSessionScript.make(
                hc: input["hc"] as! String, name: input["name"] as! String,
                id: UUID(uuidString: input["id"] as! String)!, shell: "/bin/sh",
                directory: input["directory"] as! String, program: input["program"] as! String,
                assignments: "", socket: input["socket"] as! String,
                restoring: input["restoring"] as! Bool, version: 2))
    }
}
