#!/usr/bin/env python3
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

HDC = os.getenv(
    "HARMONY_HDC",
    "/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe",
)
TARGET = os.getenv("HARMONY_TARGET", "")
WORKDIR = Path(os.getenv("HARMONY_WORKDIR", "/tmp/harmony-muse"))
WINDOWS_WORKDIR = os.getenv("HARMONY_WINDOWS_WORKDIR", r"C:\Temp\harmony-muse")
MINIMAX_PROXY = os.getenv("MINIMAX_PROXY_URL", "http://127.0.0.1:8790")
WAIT_PAGE = float(os.getenv("HARMONY_WAIT_PAGE_SECONDS", "4.5"))

BUNDLES = {
    "taobao": ("com.taobao.taobao4hmos", "Taobao_mainAbility"),
    "tmall": ("com.tmall.tmall4hmos", "TmMainAbility"),
    "jd": ("com.jd.hm.mall", "EntryAbility"),
}
EXECUTOR_BUNDLE = os.getenv("HARMONY_EXECUTOR_BUNDLE", "com.hreyulog.harmonyagent.executor")
EXECUTOR_ABILITY = os.getenv("HARMONY_EXECUTOR_ABILITY", "EntryAbility")
DEVICE_LABEL = os.getenv("HARMONY_DEVICE_LABEL", "HarmonyOS spare phone")


class SkillError(RuntimeError):
    pass


def run_hdc(*args: str, timeout: int = 20, check: bool = True) -> str:
    if not TARGET:
        raise SkillError(
            "HARMONY_TARGET is required; set it to the HDC target of the spare phone"
        )
    proc = subprocess.run(
        [HDC, "-t", TARGET, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
    )
    out = proc.stdout.replace("\r", "")
    if check and proc.returncode != 0:
        raise SkillError(f"HDC failed: {' '.join(args)} :: {out[-800:]}")
    return out


def force_stop(bundle: str) -> None:
    run_hdc("shell", "aa", "force-stop", bundle, timeout=10, check=False)
    time.sleep(0.4)


def launch(bundle: str, ability: str) -> None:
    force_stop(bundle)
    run_hdc("shell", "aa", "start", "-a", ability, "-b", bundle, timeout=15)
    time.sleep(2.5)


def click(x: int, y: int) -> None:
    run_hdc("shell", "uitest", "uiInput", "click", str(x), str(y), timeout=10)
    time.sleep(0.35)


def input_text(text: str) -> None:
    run_hdc("shell", "uitest", "uiInput", "text", text, timeout=12)
    time.sleep(0.35)


def dump_layout() -> dict[str, Any]:
    out = run_hdc("shell", "uitest", "dumpLayout", timeout=15)
    m = re.search(r"saved to:(\S+)", out)
    if not m:
        raise SkillError("dumpLayout did not return a path")
    raw = run_hdc("shell", "cat", m.group(1), timeout=15)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SkillError(f"invalid layout JSON: {exc}") from exc


def node_texts(layout: dict[str, Any], limit: int = 220) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []

    def walk(node: dict[str, Any]) -> None:
        attrs = node.get("attributes") or {}
        text = str(attrs.get("text", "")).strip()
        if text:
            rows.append({
                "text": text,
                "id": str(attrs.get("id", "")),
                "type": str(attrs.get("type", "")),
                "bounds": str(attrs.get("bounds", "")),
                "bundle": str(attrs.get("bundleName", "")),
            })
        for child in node.get("children") or []:
            if isinstance(child, dict):
                walk(child)

    walk(layout)
    return rows[:limit]


def parse_bounds(value: str) -> tuple[int, int, int, int] | None:
    m = re.match(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", value or "")
    if not m:
        return None
    return tuple(int(x) for x in m.groups())


def center_y(row: dict[str, str]) -> float | None:
    bounds = parse_bounds(row.get("bounds", ""))
    if not bounds:
        return None
    return (bounds[1] + bounds[3]) / 2.0


def center_x(row: dict[str, str]) -> float | None:
    bounds = parse_bounds(row.get("bounds", ""))
    if not bounds:
        return None
    return (bounds[0] + bounds[2]) / 2.0


def normalize_token(text: str) -> str:
    return re.sub(r"\s+", "", text).lower()


def price_candidates(rows: list[dict[str, str]]) -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    for idx, row in enumerate(rows):
        text = row["text"].strip()
        direct = re.search(r"[¥￥]\s*([0-9]+(?:\.[0-9]+)?)", text)
        if direct:
            candidates.append({
                "value": direct.group(1),
                "text": text,
                "x": center_x(row),
                "y": center_y(row),
            })
            continue
        if re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", text):
            y = center_y(row)
            x = center_x(row)
            if y is None or x is None:
                continue
            for other in rows[max(0, idx - 5): idx + 5]:
                if other["text"].strip() not in {"¥", "￥"}:
                    continue
                oy = center_y(other)
                ox = center_x(other)
                if oy is None or ox is None:
                    continue
                if abs(oy - y) <= 35 and ox < x and x - ox <= 180:
                    candidates.append({
                        "value": text,
                        "text": "¥" + text,
                        "x": x,
                        "y": y,
                    })
                    break
    return candidates


def deterministic_cards(platform: str, query: str, rows: list[dict[str, str]]) -> list[dict[str, Any]]:
    query_norm = normalize_token(query)
    title_rows: list[dict[str, str]] = []
    for row in rows:
        text = row["text"].strip()
        norm = normalize_token(text)
        if "mate80" not in norm:
            continue
        if norm == query_norm or len(text) < 12:
            continue
        title_rows.append(row)

    prices = price_candidates(rows)
    output: list[dict[str, Any]] = []
    seen: set[tuple[str, str | None]] = set()

    for title_row in title_rows:
        title = title_row["text"].strip()
        ty = center_y(title_row)
        if ty is None:
            continue

        if platform == "tmall":
            eligible = [p for p in prices if p["y"] is not None and 50 <= ty - p["y"] <= 360]
        else:
            eligible = [p for p in prices if p["y"] is not None and 50 <= p["y"] - ty <= 420]
        if not eligible:
            continue
        price = min(eligible, key=lambda p: abs(float(p["y"]) - ty))

        nearby = []
        for row in rows:
            ry = center_y(row)
            if ry is None:
                continue
            if abs(ry - ty) <= 650:
                nearby.append(row["text"].strip())

        shop: str | None = None
        shop_candidates = [
            text for text in nearby
            if any(k in text for k in ("旗舰店", "自营", "专营店", "官方精选"))
            and "Mate 80" not in text
            and "Mate80" not in text
        ]
        if shop_candidates:
            shop = min(shop_candidates, key=len)

        if platform == "jd":
            official = bool(
                shop and any(k in shop for k in ("京东自营", "华为官方旗舰店", "华为京东自营"))
            )
        else:
            official = any(
                k in (" ".join(nearby) + " " + (shop or ""))
                for k in ("华为官方旗舰店", "自营旗舰店", "官方精选", "臻选官旗")
            )

        subsidy: str | None = None
        labels_near_price = []
        py = float(price["y"])
        for row in rows:
            ry = center_y(row)
            if ry is not None and abs(ry - py) <= 90:
                labels_near_price.append(row["text"].strip())
        if platform == "tmall" and any("补贴后" in x or "到手" in x for x in labels_near_price):
            subsidy = "¥" + str(price["value"])

        key = (title, str(price["value"]))
        if key in seen:
            continue
        seen.add(key)
        output.append({
            "platform": platform,
            "title": title,
            "price": "¥" + str(price["value"]),
            "subsidyPrice": subsidy,
            "shop": shop,
            "official": official,
            "extraction": "ui_tree_rule",
            "labels": labels_near_price[:8],
        })
        if len(output) >= 6:
            break
    return output


def screenshot(name: str) -> Path:
    remote = f"/data/local/tmp/{name}.png"
    WORKDIR.mkdir(parents=True, exist_ok=True)
    windows = WINDOWS_WORKDIR.rstrip("\\/") + "\\" + f"{name}.png"
    local = WORKDIR / f"{name}.png"
    run_hdc("shell", "uitest", "screenCap", "-p", remote, timeout=15)
    run_hdc("file", "recv", remote, windows, timeout=20)
    if not local.is_file() or local.stat().st_size < 1000:
        raise SkillError("screenshot receive failed")
    return local


def proxy_json(path: str, payload: dict[str, Any], timeout: int = 90) -> dict[str, Any]:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        MINIMAX_PROXY + path,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except Exception as exc:
        raise SkillError(f"MiniMax proxy failed: {exc}") from exc


def parse_model_json(text: str) -> Any:
    text = text.strip()
    fenced = re.search(r"\x60\x60\x60(?:json)?\s*(.*?)\x60\x60\x60", text, re.S | re.I)
    if fenced:
        text = fenced.group(1).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    start_candidates = [i for i in (text.find("["), text.find("{")) if i >= 0]
    if start_candidates:
        start = min(start_candidates)
        for end_char in ("]", "}"):
            end = text.rfind(end_char)
            if end > start:
                try:
                    return json.loads(text[start:end + 1])
                except json.JSONDecodeError:
                    pass
    raise SkillError("model did not return valid JSON")


def extract_tree(platform: str, query: str, rows: list[dict[str, str]]) -> list[dict[str, Any]]:
    evidence = "\n".join(
        f"{idx+1}. {r['bounds']} | {r['text']}" for idx, r in enumerate(rows)
    )
    prompt = f"""
你是购物搜索结果结构化抽取器。
平台：{platform}
查询：{query}

下面是该平台真实 HarmonyOS App 当前页面的可见 UI 文本节点。
只抽取与“{query}”匹配的商品。不要根据常识补价格，不要猜不可见信息。
如果是 Mate 80 Pro，title 必须明确保留 Pro；不要把 Pro 当成普通 Mate 80。

返回严格 JSON 数组，每项字段：
platform, title, price, subsidyPrice, shop, official, extraction
其中 platform 固定为 "{platform}"，extraction 固定为 "ui_tree"。
official 只有文本明确显示官方旗舰店、自营、官方精选等时才能 true，否则 false 或 null。
最多返回 6 条；没有可靠结果返回 []。

UI 节点：
{evidence}
""".strip()
    data = proxy_json("/plan", {"goal": prompt}, timeout=75)
    if not data.get("ok"):
        raise SkillError(str(data.get("error") or "tree extraction failed"))
    parsed = parse_model_json(str(data.get("content") or ""))
    if not isinstance(parsed, list):
        raise SkillError("tree extraction was not an array")
    return [x for x in parsed if isinstance(x, dict)]


def extract_vision(platform: str, query: str, image: Path) -> list[dict[str, Any]]:
    prompt = f"""
这是 {platform} HarmonyOS App 中搜索“{query}”后的真实手机截图。
只抽取截图中能明确读到、与“{query}”匹配的商品。
不要猜看不清的价格、补贴或店铺。
如果是 Mate 80 Pro，title 必须明确保留 Pro；不要和普通 Mate 80 混为一条。

返回严格 JSON 数组，每项：
platform, title, price, subsidyPrice, shop, official, extraction
platform 固定为 "{platform}"，extraction 固定为 "vision"。
official 只有截图明确显示官方旗舰、自营等证据时才为 true，否则 false 或 null。
最多 6 条；没有可靠结果返回 []。
""".strip()
    data = proxy_json(
        "/vision",
        {
            "prompt": prompt,
            "imageBase64": base64.b64encode(image.read_bytes()).decode("ascii"),
            "mediaType": "image/png",
        },
        timeout=90,
    )
    if not data.get("ok"):
        raise SkillError(str(data.get("error") or "vision extraction failed"))
    parsed = parse_model_json(str(data.get("content") or ""))
    if not isinstance(parsed, list):
        raise SkillError("vision extraction was not an array")
    return [x for x in parsed if isinstance(x, dict)]


def search_jd(query: str) -> tuple[list[dict[str, Any]], str]:
    payload = {
        "des": "productList",
        "keyWord": query,
        "from": "search",
        "category": "jump",
    }
    uri = "openapp.jdmobile://virtual?params=" + urllib.parse.quote(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    )
    force_stop(BUNDLES["jd"][0])
    run_hdc("shell", "aa", "start", "-A", "ohos.want.action.viewData", "-U", uri, timeout=15)
    time.sleep(WAIT_PAGE)
    rows = node_texts(dump_layout())
    return deterministic_cards("jd", query, rows), "deep_link+ui_tree_rule"


def search_tmall(query: str) -> tuple[list[dict[str, Any]], str]:
    bundle, ability = BUNDLES["tmall"]
    launch(bundle, ability)
    # Home search field and submit button on the verified Nova 15 Pro layout.
    click(555, 372)
    input_text(query.replace(" ", ""))
    click(1000, 245)
    time.sleep(WAIT_PAGE)
    rows = node_texts(dump_layout())
    return deterministic_cards("tmall", query, rows), "uitest+ui_tree_rule"


def search_taobao(query: str) -> tuple[list[dict[str, Any]], str]:
    bundle, ability = BUNDLES["taobao"]
    launch(bundle, ability)
    click(575, 369)
    input_text(query.replace(" ", ""))
    click(1150, 369)
    time.sleep(WAIT_PAGE)
    rows = node_texts(dump_layout())
    relevant = [
        r for r in rows
        if re.search(r"Mate\s*80|Mate80|华为|¥|￥|补贴|旗舰|官方", r["text"], re.I)
    ]
    if len(relevant) >= 4:
        try:
            items = extract_tree("taobao", query, rows)
            if items:
                return items, "uitest+ui_tree"
        except SkillError:
            pass
    img = screenshot("shopping_compare_taobao")
    items = extract_vision("taobao", query, img)
    if items:
        return items, "uitest+vision"
    time.sleep(3.0)
    img = screenshot("shopping_compare_taobao_retry")
    return extract_vision("taobao", query, img), "uitest+vision_retry"


def normalize_item(item: dict[str, Any], platform: str) -> dict[str, Any]:
    return {
        "platform": str(item.get("platform") or platform),
        "title": item.get("title"),
        "price": item.get("price"),
        "subsidyPrice": item.get("subsidyPrice"),
        "shop": item.get("shop"),
        "official": item.get("official"),
        "extraction": item.get("extraction"),
    }


def restore_executor_app() -> None:
    run_hdc(
        "shell", "aa", "start",
        "-a", EXECUTOR_ABILITY,
        "-b", EXECUTOR_BUNDLE,
        timeout=15,
        check=False,
    )
    time.sleep(0.8)


def run_skill(query: str) -> dict[str, Any]:
    results: dict[str, Any] = {}
    warnings: list[str] = []
    all_items: list[dict[str, Any]] = []
    adapters = [
        ("taobao", search_taobao),
        ("tmall", search_tmall),
        ("jd", search_jd),
    ]
    try:
        for platform, fn in adapters:
            try:
                items, method = fn(query)
                normalized = [normalize_item(x, platform) for x in items]
                results[platform] = {"ok": True, "method": method, "items": normalized}
                all_items.extend(normalized)
            except Exception as exc:
                results[platform] = {"ok": False, "error": str(exc)[:500], "items": []}
                warnings.append(f"{platform}: {str(exc)[:300]}")
        return {
            "skill": "shopping-compare",
            "query": query,
            "device": DEVICE_LABEL,
            "platforms": results,
            "items": all_items,
            "warnings": warnings,
        }
    finally:
        restore_executor_app()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--query", required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(run_skill(args.query), ensure_ascii=False, indent=2))
        return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
