# Harmony Muse: two-device single-runtime prototype

## Summary

Harmony Muse explores a different system shape from the original ChebyAgent Android appliance.

ChebyAgent packages a Linux user space plus Codex into one Android phone and bridges Codex to the Android framework. Harmony Muse instead uses two user devices:

```
Primary HarmonyOS phone
  lightweight task console
        |
        | HTTPS / WebSocket relay
        v
Spare HarmonyOS phone
  AgentRuntime
  SkillRuntime
  PolicyGate
  HarmonyBridge
        |
        v
  installed real apps
```

The cloud is not the execution computer. It is only a transport / pairing / offline-message layer. The user-owned spare phone is the execution environment.

## Why keep it in Sofia

Sofia already contains the architectural ideas we want to reuse:

- rich task/chat front-end concepts,
- Skills as reusable SOPs,
- a phone bridge boundary,
- action authorization / policy concepts,
- relay and task identity work,
- idempotent task delivery patterns.

The HarmonyOS implementation keeps those boundaries while replacing the Android + PRoot/Codex appliance with a single native HarmonyOS runtime.

## Prototype directories

- `Android/app/` — existing Sofia Jetpack Compose UI; preserved unchanged.
- `HarmonyOS/harmony-muse-app/` — parallel HarmonyOS ArkUI / ArkTS front end for the two-device product.
- `skills/shopping-compare/` — first end-to-end Skill.
- `prototype/harmony-muse/` — development AgentRuntime, MiniMax proxy and Relay.

## Front-end strategy

Harmony Muse does **not** replace Sofia's Android front end. The repository intentionally keeps two
platform front ends:

```
Sofia product UI
├── Android/app/                  Jetpack Compose
└── HarmonyOS/harmony-muse-app/   ArkUI / ArkTS
```

The HarmonyOS front end adapts the same product concepts — conversation-first task entry, runtime
status, task cards, result cards and approval-oriented execution — to ArkUI while adding the
PRIMARY / EXECUTOR two-device roles required by the Muse-style architecture.

## Validated scenario

User on the primary phone submits:

> 比较淘宝、天猫、京东上的华为 Mate 80，优先官方旗舰店或京东自营，给出价格、补贴到手价和简短购买建议。

The spare phone then:

1. receives the task;
2. MiniMax selects `shopping-compare`;
3. searches the installed Taobao, Tmall and JD HarmonyOS apps;
4. extracts visible product / price / shop evidence;
5. uses multimodal extraction only when an app renders product cards outside the accessibility tree;
6. summarizes the evidence with MiniMax;
7. returns a terminal result to the primary phone.

## Skill adapters

### JD
Native deep link to the product list + UITest tree parsing.

### Tmall
Open native app -> focus search -> type query -> submit -> UITest tree parsing.

### Taobao
Open native app -> search -> UITest where available -> screenshot + MiniMax Vision fallback for custom-rendered cards.

## Safety boundary

The first Skill is browse-only. It may search, inspect and summarize. It must not add to cart, create an order, checkout, pay, or modify account/payment settings.

## Prototype limitations

The current HarmonyBridge is a development implementation using HDC + UITest from a development computer. Therefore this branch proves the product interaction and Skill architecture, not yet the final disconnected runtime.

The next acceptance test is:

> Disconnect USB / development computer; the spare phone still completes the same comparison task and returns the result.

That milestone requires moving AgentRuntime, SkillRuntime and HarmonyBridge execution fully onto the spare phone.
