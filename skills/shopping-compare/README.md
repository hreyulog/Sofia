# shopping_compare

Development implementation of the Harmony Muse shopping comparison Skill.

Current execution backend:
- Nova 15 Pro spare phone
- HDC + UITest for native HarmonyOS app observation/control
- MiniMax-M3 vision fallback for custom-rendered Taobao result cards

This is intentionally the same separation used by ChebyAgent:
Agent -> SKILL.md -> phone bridge/tool layer -> real apps.

The HDC backend is temporary. Production should replace it with the on-device HarmonyBridge while keeping the Skill contract stable.
