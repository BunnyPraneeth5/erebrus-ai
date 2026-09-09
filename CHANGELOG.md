# Changelog

Notable user-facing changes to Erebrus AI are documented here.

## Unreleased

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
