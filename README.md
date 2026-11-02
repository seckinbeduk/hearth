# Hearth

Your Mac's own AI, in the menu bar.

Hearth scans your Mac, tells you which local model it runs best, downloads it, and serves it on an
OpenAI-compatible endpoint at `http://localhost:8800/v1`. The menu bar shows live tokens/sec, today's
requests and which apps are calling.

- **Zero decisions.** One recommendation for *your* chip, memory and disk, with the reason.
- **Uses what you already have.** Finds Ollama, LM Studio and other servers already running, and models
  already on disk. MLX models in your Hugging Face cache start without a download. For Ollama/LM Studio
  models, Hearth estimates their speed here and suggests a faster MLX option when there is one.
- **Apple Intelligence included.** On macOS 26 with Apple Intelligence on, the on-device model is served as
  `apple-intelligence` on the same endpoint. Free, nothing to download.
- **Local only.** The server listens on the loopback interface. Nothing leaves your Mac.

Requires an Apple Silicon Mac with macOS 15 or later.

## Use it

```bash
curl http://localhost:8800/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "hearth", "messages": [{"role": "user", "content": "Hello"}], "stream": true}'
```

Any OpenAI SDK works: set `base_url` to `http://localhost:8800/v1` and any API key.
`model` can be `hearth` (whatever is loaded), the model's id, or `apple-intelligence`.

Both models are served side by side: requests for `apple-intelligence` don't wait behind the MLX queue,
so a quick summary can run while a long local job is generating.

Endpoints: `GET /v1/models`, `POST /v1/chat/completions` (streaming and non-streaming, `stream_options.include_usage`),
`GET /health`.

## Build

Needs Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/seckinbeduk/hearth.git
cd hearth
./run.sh          # build and launch (look for the flame in the menu bar)
./run.sh test     # unit tests
./release.sh      # DMG for sharing
```

`release.sh` signs and notarizes when a "Developer ID Application" certificate is in your keychain.
Without one it still makes a DMG; on the other Mac, open it once, then
System Settings → Privacy & Security → **Open Anyway**.

## How the recommendation works

1. **Budget:** Metal's recommended GPU working set. "Runs well" means the model + 8K context KV cache uses at
   most 65% of it; "Tight fit" up to 85%.
2. **Speed estimate:** memory bandwidth × 0.7 ÷ weights read per token (MoE models only read active experts).
   Below 12 tok/s a model is marked "Slow here". After the first request, Hearth shows the measured speed next
   to the estimate.
3. **Pick:** the highest-quality general model that runs well, with a small bonus for speed. If a model that's
   nearly as good and not much slower is already downloaded, Hearth picks that one instead.

## Layout

| Folder | What's inside |
|---|---|
| `Hardware/` | Chip, cores, GPU, memory, disk, Apple Intelligence status; live memory pressure and heat |
| `Discovery/` | Running servers (Ollama, LM Studio, Jan, GPT4All, :8080, :8000) and models on disk |
| `Models/` | Catalog (`Resources/models.json`), advisor, MLX download/load |
| `Server/` | Loopback HTTP server, OpenAI types, MLX + Apple Intelligence backends |
| `Stats/` | Live tok/s, today's totals, per-app usage, recent requests |
| `UI/` | Menu bar label and panel, setup window, dashboard |

## Roadmap

Done in 0.1: hardware scan and recommendation, models already on disk, OpenAI-compatible server,
Apple Intelligence side by side, live menu bar, persistent request history, TTFT and per-model medians,
measured prompt speed (MLX), 2-minute activity graph, savings vs cloud, Markdown in Try it.

Next:
- [ ] GPU utilization % (IORegistry, no root needed)
- [ ] Context fill per request and a warning when an answer is cut off at the token limit
- [ ] Speed vs context length (why long answers slow down)
- [ ] Memory breakdown: model weights vs KV cache
- [ ] Battery draw while generating (watts, % per 1K tokens) on laptops
- [ ] 7-day usage chart per day and per app
- [ ] Model card: parameters, quantization, context window, license, location on disk, last used
- [ ] Find models inside other apps' sandboxes and clone them into the shared cache (APFS clone, no extra disk)
- [ ] Sparkle auto-updates and a landing page
- [ ] Developer ID signing and notarization
- [ ] Turkish localization
- [ ] Remote model catalog (new models without an app update)
- [ ] Optional: serve to other devices on your network, with a key
