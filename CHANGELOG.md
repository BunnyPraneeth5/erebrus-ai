# Changelog

Notable user-facing changes to Erebrus AI are documented here.

## 1.1.0+2 — 2026-09-29

### Sign-in fixes

- Android: resume the existing app when a wallet or browser returns the
  `erebrusai://` sign-in callback (`singleTask`), instead of starting a second
  app instance in the other app's task, which restarted the app mid sign-in.
- Close the sign-in page exactly once after a successful login; the email
  code sheet and Reown wallet modal no longer pop the home screen, which left
  a blank screen.
- Close the Reown modal before persisting the session, ignore duplicate
  wallet-connect events, and fail cleanly if the wallet disconnects before
  signing.
- Seeker/Saga: report a closed or missing wallet instead of waiting forever.
- Browser sign-in survives the OS killing the app while the browser is open
  (the anti-forgery state is persisted for 15 minutes).
- Gateway requests time out (15 s connect, 30 s response) with readable
  errors, and app launch no longer waits on the network to restore a saved
  session.
- Sign-out always completes even if the wallet disconnect fails.
- Cached organizations are scoped to the signed-in account and deleted on
  sign-out.

### Settings

- Redesign Settings as a searchable, sectioned surface (Account, General,
  Local server, Connections, Voice, Data, About): a two-pane layout on desktop
  and a drill-in section list on phones.
- Show the model resident in memory under General → Model memory, with
  one-tap Load and Offload.
- Buttons, toggles and values stay right-aligned beside their label when it
  fits on one line, and move under it (still right-aligned) only when they
  would squeeze it — so labels and buttons never wrap on small phones. The
  same rule applies to Models cards, Transcribe setup cards and Connections.

### Connections

- Add model connections for llama.cpp, Ollama, LM Studio, vLLM, other Erebrus
  nodes (by address), OpenAI, Anthropic, OpenRouter, and any OpenAI-compatible
  endpoint. API keys are stored in the system keychain.
- List a server's available models, choose which ones to use, or enter model
  IDs manually; an optional per-connection Max Tokens cap applies to requests.
- See live model memory state and load or offload models remotely on
  llama-server (router mode), Ollama, LM Studio, and Erebrus nodes.
- llama.cpp: detect router mode from `/props`; single-model servers show
  their model as loaded without Load/Offload. Router loads finish in the
  background, so the app follows the model to LOADED/FAILED; repeating a
  load or offload is treated as already done. Verified end to end against
  llama-server b11160 (list, load, streamed chat with history, offload).
- Connection models appear in Chat's model picker and in Models → Network;
  chats with network models now send recent conversation history.
- Erebrus nodes expose `POST /v1/models/load` and `/v1/models/unload`, and
  `/v1/models` reports each model's load state.

### Model loading

- On-device models load only when you press **Load** next to the model
  name in Chat, and **Eject** frees their memory. Selecting a model no
  longer loads it, sending to an unloaded model offers a Load action, and
  switching tabs no longer unloads it behind your back.
- The chat header shows the real state (NOT LOADED / LOADING / LOADED /
  GENERATING). The model picker and Models cards show LOADED only for the
  model in memory; other downloads show READY / DOWNLOADED.
- Remote models (Connections, LAN nodes) are used directly with no Load step.
  Remote devices using this Mac's LAN server still load models on demand.

### Chat formatting

- Assistant replies render Markdown instead of raw symbols: headings, bold,
  italic, strikethrough, inline code, links, bullet/numbered/nested/task
  lists, blockquotes, rules, tables, and fenced code blocks with a language
  label and Copy button. Citations like [2] are tappable and open their
  source. Replies are selectable, and partially streamed Markdown renders
  cleanly (an unfinished code block shows as code).

### Web search and tool calling

- New Settings → Tools: let tool-capable models search the web and read
  pages. Choose SearXNG (self-hosted, no key), Brave Search or Tavily (API
  key kept in the system keychain), results per search, and whether pages
  may be opened; "Test search" checks the setup.
- Chat has a globe button to turn web search on per chat. Connection models
  run an agent loop (up to 5 steps): each search or page read appears as a
  step under the answer, with numbered source chips matching [n] citations.
- Page reads only reach public sites; this device and private/local network
  addresses are refused, including via redirects. Tool output is framed as
  untrusted content for the model.
- Streamed chat requests no longer reuse a connection the server already
  closed ("Connection closed before full header"), which intermittently
  broke the request after a tool step. Verified live with llama-server
  (Qwen3-0.6B, `--jinja`), a real SearXNG instance, and real page reads.
- The composer footer now states where a message goes (on-device, network,
  or cloud provider) and which search service is used, replacing a
  hard-coded context counter.

### Voice

- Choose the dictation engine (automatic, system speech, or local Whisper),
  the Whisper model (Tiny, Base, Base English, Small, Large v3 Turbo), and
  the default dictation language; every model is checksum-verified.
- Toggle the read-aloud button on assistant responses and pick TTS voice,
  rate, and pitch from the Voice page.
- Transcribe follows Voice changes immediately (language, engine, speech
  model, downloads) instead of after a restart, and the Microphone row shows
  the real permission state.

### Desktop

- Run as a true menu-bar/system-tray app: closing the window hides it while
  keeping background services and the tray icon active.
- Remove the Dock/taskbar icon and use the tray icon as the sole way to reopen
  the window; quitting remains an explicit tray-menu action.

## 1.0.2+1 — 2026-08-19

### Authentication and sessions

- Preserve the HTTP status and gateway error code in authentication and
  organization API exceptions.
- Sign out safely when a bearer-authenticated request returns `401`, clearing
  the in-memory token and persisted session exactly once.
- Show “Your session expired. Please sign in again.” when an expired session
  moves the app into signed-out state.
- Revalidate stored authentication before restoring a session and whenever the
  app resumes.
- Keep users signed in after `403`, connectivity, and server failures so those
  errors remain recoverable.

### Model catalog

- Add a desktop catalog browser with a searchable model list and a dedicated
  details and download pane.
- Parse and display catalog-backed publisher, architecture, capabilities,
  context, usage guidance, limitations, license, provenance, runtime
  verification, and GPU-offload support.
- Present only packages compatible with the detected device and active
  inference backends, including verified GGUF and MLX variants.
- Keep imported models accessible from the desktop catalog and retain the
  compact card-based Models experience on mobile.
- Display the resolved Erebrus models-folder path on the Models screen.
- Omit mutable or unavailable metadata such as download counts, star counts,
  relative update age, remote README content, and fabricated model logos.

### Validation

- Add regression coverage for session expiry, structured API errors, catalog
  metadata parsing, desktop model details, folder-path visibility, and
  responsive Models layouts.
