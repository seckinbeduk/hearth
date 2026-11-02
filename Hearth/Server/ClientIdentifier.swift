import Foundation

/// Turns request headers into a friendly app name for "Who's using it".
enum ClientIdentifier {
    static func name(userAgent: String?, title: String?) -> String {
        // OpenRouter-style app title wins when a client sets it.
        if let title, !title.isEmpty { return title }
        guard let ua = userAgent?.trimmingCharacters(in: .whitespaces), !ua.isEmpty else { return "Unknown app" }
        let lower = ua.lowercased()

        let known: [(String, String)] = [
            ("cursor", "Cursor"),
            ("continue", "Continue"),
            ("zed", "Zed"),
            ("raycast", "Raycast"),
            ("cline", "Cline"),
            ("roo", "Roo Code"),
            ("vscode", "VS Code"),
            ("openwebui", "Open WebUI"),
            ("open-webui", "Open WebUI"),
            ("langchain", "LangChain"),
            ("llamaindex", "LlamaIndex"),
            ("openai/python", "Python"),
            ("python-httpx", "Python"),
            ("python-requests", "Python"),
            ("aiohttp", "Python"),
            ("openai/js", "Node.js"),
            ("node", "Node.js"),
            ("curl/", "curl"),
            ("wget/", "wget"),
            ("postman", "Postman"),
            ("insomnia", "Insomnia"),
            ("hearth", "Hearth"),
        ]
        if let match = known.first(where: { lower.contains($0.0) }) { return match.1 }
        if lower.hasPrefix("mozilla/") { return "Browser" }

        // Fall back to the product token: "MyTool/1.2 (macOS)" → "MyTool"
        let product = ua.split(separator: "/").first.map(String.init) ?? ua
        return String(product.prefix(24))
    }

    /// SF Symbol for the client list.
    static func symbol(for name: String) -> String {
        switch name {
        case "Cursor", "VS Code", "Zed", "Continue", "Cline", "Roo Code": "chevron.left.forwardslash.chevron.right"
        case "Python", "Node.js", "LangChain", "LlamaIndex": "curlybraces"
        case "curl", "wget", "Postman", "Insomnia": "terminal"
        case "Browser", "Open WebUI": "safari"
        case "Raycast": "command"
        case "Hearth": "flame"
        default: "app"
        }
    }
}
