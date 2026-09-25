---
name: shopping-compare
description: Compare a product across the installed Taobao, Tmall and JD HarmonyOS apps on the spare Nova phone. Collect visible product titles, prices, subsidy prices and shop/channel evidence, then return normalized evidence for the agent to summarize. Read-only: never add to cart, order, checkout or pay.
---

# Shopping comparison on the spare HarmonyOS phone

Use the installed Taobao, Tmall and JD apps through the local HarmonyBridge development backend.

## Input

- `query`: product query, for example `华为 Mate 80`.
- Default platforms: Taobao, Tmall and JD.

## Workflow

1. Search all three installed native apps on the spare Nova phone.
2. Prefer exact matches for the requested model. Do not silently mix Mate 80 and Mate 80 Pro.
3. Prefer official flagship, platform self-operated, or clearly identified official channels.
4. Collect only evidence actually visible in the app:
   - product title
   - displayed price
   - displayed subsidy / after-subsidy wording
   - shop/channel
   - whether the shop is visibly official/self-operated
5. Normalize evidence by platform.
6. Return the normalized evidence to the main model for comparison and summary.

## Platform adapters

### JD

Use the native JD product-list deep link for the query. Read the visible UITest tree and extract matching product cards, prices, subsidy wording and JD self-operated/official channel evidence.

### Tmall

Open the native Tmall app, focus the search field, input the query, submit search, then read the UITest tree. Group nearby title / price / subsidy / shop labels into product observations.

### Taobao

Open the native Taobao app, focus the search field, input the query and submit search. Taobao's HarmonyOS result cards may not expose full accessibility nodes, so use the UITest tree when sufficient and fall back to a fresh screenshot interpreted by the same multimodal model. Never invent unreadable prices.

## Output

Return JSON with:
- `query`
- `platforms`
- `items[]`: platform, title, price, subsidyPrice, shop, official, extraction
- `warnings[]`

The final user-facing recommendation is produced by the main model, not by this adapter.

## Boundaries

This Skill is browse/search only. Never:
- add to cart
- create or submit an order
- checkout
- pay
- change an account, address or payment setting

If a later workflow needs a side-effecting action, stop and request explicit user approval first.
