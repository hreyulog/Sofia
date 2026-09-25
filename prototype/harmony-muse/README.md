# Harmony Muse prototype runtime

This directory contains the prototype control plane used by the two-device HarmonyOS demo.

The system shape differs from the original single-phone ChebyAgent runtime:

- **Primary phone**: lightweight Muse-style task console.
- **Spare phone**: persistent execution device.
- **Cloud relay**: transport only; it does not host the Agent computer.
- **Agent runtime**: routes natural-language tasks to Skills.
- **HarmonyBridge**: currently a development backend implemented with HDC + UITest.

## Components

- `minimax_proxy.js` — keeps the MiniMax token off the phones and exposes `/plan` and `/vision`.
- `agent_runtime.py` — loads installed Skills, routes tasks with MiniMax, executes the selected Skill and summarizes evidence.
- `relay.js` — prototype primary/executor task queues plus asynchronous task completion delivery.
- `run-dev.sh` — local development launcher.

## Setup

1. Copy `.env.example` to `.env`.
2. Put your MiniMax token in a file outside the repository and set `MINIMAX_TOKEN_FILE`.
3. Set `HARMONY_TARGET` to the spare phone shown by `hdc list targets`.
4. Set `HARMONY_HDC` to the local HDC executable.
5. Start the runtime:

```bash
cp prototype/harmony-muse/.env.example prototype/harmony-muse/.env
# edit .env
prototype/harmony-muse/run-dev.sh
```

For cross-network phones, expose only the Relay HTTPS endpoint. Do not expose the MiniMax proxy directly.

## Current end-to-end demo

The validated scenario is:

> Compare Huawei Mate 80 prices in the installed Taobao, Tmall and JD apps, prefer official flagship / JD self-operated channels, summarize visible prices and subsidy wording, and return the result to the primary phone.

Flow:

```
primary phone
  -> TASK_REQUEST
relay
  -> spare phone executor
  -> MiniMax routes to shopping-compare
  -> Taobao / Tmall / JD on the spare phone
  -> normalized evidence
  -> MiniMax summary
relay
  -> TASK_COMPLETED
primary phone
```

The Skill is read-only. It never adds to cart, submits an order or pays.

## Production migration target

HDC + UITest is deliberately isolated behind the Skill/bridge boundary. The next milestone is replacing that backend with an on-device HarmonyOS bridge so the spare phone can execute after USB and the development computer are disconnected.
