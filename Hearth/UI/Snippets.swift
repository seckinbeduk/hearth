import Foundation

/// Copy-paste examples for the running endpoint.
enum Snippet: String, CaseIterable, Identifiable {
    case curl = "curl"
    case python = "Python"
    case javascript = "JavaScript"
    case apps = "Apps and editors"

    var id: String { rawValue }

    func code(baseURL: String, model: String) -> String {
        switch self {
        case .curl:
            """
            curl \(baseURL)/chat/completions \\
              -H "Content-Type: application/json" \\
              -d '{
                "model": "\(model)",
                "messages": [{"role": "user", "content": "Hello from my Mac"}],
                "stream": true
              }'
            """
        case .python:
            """
            # pip install openai
            from openai import OpenAI

            client = OpenAI(base_url="\(baseURL)", api_key="hearth")
            stream = client.chat.completions.create(
                model="\(model)",
                messages=[{"role": "user", "content": "Hello from my Mac"}],
                stream=True,
            )
            for chunk in stream:
                print(chunk.choices[0].delta.content or "", end="", flush=True)
            """
        case .javascript:
            """
            // npm install openai
            import OpenAI from "openai";

            const client = new OpenAI({ baseURL: "\(baseURL)", apiKey: "hearth" });
            const stream = await client.chat.completions.create({
              model: "\(model)",
              messages: [{ role: "user", content: "Hello from my Mac" }],
              stream: true,
            });
            for await (const chunk of stream) {
              process.stdout.write(chunk.choices[0]?.delta?.content ?? "");
            }
            """
        case .apps:
            """
            Any app with an "OpenAI-compatible" or "custom base URL" setting works:

              Base URL   \(baseURL)
              API key    hearth   (anything; Hearth doesn't check it)
              Model      \(model)

            Continue, Cline, Zed, Open WebUI, Raycast and most AI tools have this setting.
            Use model "apple-intelligence" to reach the on-device Apple model instead.

            Note: Cursor sends custom-model requests from its own servers,
            so it can't reach localhost without a tunnel.
            """
        }
    }
}
