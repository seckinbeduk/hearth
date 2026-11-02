# Contributing to Hearth

Thanks for taking a look. Hearth is small on purpose: scan the Mac, run the right local model, show what's happening.
Changes that keep it simple are the easiest to merge.

## Getting started

```bash
brew install xcodegen
git clone https://github.com/seckinbeduk/hearth.git
cd hearth
./run.sh        # build and launch
./run.sh test   # unit tests (full log in .build/test.log)
```

The Xcode project is generated from `project.yml`; don't commit `Hearth.xcodeproj`.

## Good first contributions

- **Model catalog.** Add a model to `Hearth/Resources/models.json` with its real disk size, active size (for MoE)
  and KV cache per token. Please say which Mac you tested it on and the speed you measured.
- **Speed reports.** Open an issue with your chip, memory, the recommended model, and the estimated vs measured
  tok/s from the dashboard. These help tune the advisor.
- **Discovery.** Other local LLM servers or model folders Hearth should find.
- Anything on the [roadmap](README.md#roadmap).

## Guidelines

- Swift 6 with strict concurrency; UI state lives on the main actor.
- No new dependencies without a good reason.
- Never store prompts or replies. Request history is metadata only.
- Keep the server on the loopback interface by default.
- Add or update tests in `HearthTests/` when you change the advisor, the HTTP parsing or the OpenAI types.

## Reporting bugs

Include your Mac (chip, memory), macOS version, the model, and what you expected vs what happened.
For server issues, the exact request (curl is best) and the response help a lot.
