# Sofia Harmony Muse App

Native HarmonyOS two-device prototype UI.

This is a **parallel ArkUI / ArkTS front end**. It does not replace or modify Sofia's existing
`Android/app/` Jetpack Compose UI.

A single HAP can run in two roles:

- **PRIMARY** — task entry, progress, approval/result display.
- **EXECUTOR** — spare-phone task receiver and execution status.

The primary-phone screen follows the same conversation-first product shape as Sofia: a top app bar,
connected-device state, assistant/user message surfaces, a task status card, a rich result card and
a bottom composer. The executor screen reuses the visual language but focuses on device/runtime
state and the currently delegated task.

The current prototype identifies known development devices by product model in `Index.ets`. Before generalizing the prototype, replace model-based role assignment with device pairing / persisted role configuration.

## Build

Open this directory in DevEco Studio, configure your own automatic or manual signing profile, and replace the prototype `RELAY_BASE` in:

`entry/src/main/ets/pages/Index.ets`

Do not commit signing passwords, `.p12`, `.p7b` or developer certificates.

The checked-in `build-profile.json5` intentionally contains no signing material.

## Current role flow

```
PRIMARY
  TASK_REQUEST
       |
       v
    Relay
       |
       v
EXECUTOR
  TASK_ACCEPTED
  TASK_PROGRESS
  TASK_COMPLETED / TASK_FAILED
       |
       v
    Relay
       |
       v
PRIMARY
```
