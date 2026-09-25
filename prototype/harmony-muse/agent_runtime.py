#!/usr/bin/env python3
import json, os, re, subprocess, threading, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MINIMAX = os.getenv("MINIMAX_PLAN_URL", "http://127.0.0.1:8790/plan")
RUNNER = os.getenv(
    "SHOPPING_COMPARE_RUNNER",
    str(REPO_ROOT / "skills" / "shopping-compare" / "runner.py"),
)
SKILL = Path(
    os.getenv(
        "SHOPPING_COMPARE_SKILL",
        str(REPO_ROOT / "skills" / "shopping-compare" / "SKILL.md"),
    )
)
TASK_LOCK = threading.Lock()
TASK_EVENTS = {}
TASK_RESULTS = {}
TASK_ERRORS = {}
TASK_GOALS = {}
MAX_TASK_CACHE = 100

def post(url, payload, timeout=120):
    body = json.dumps(payload, ensure_ascii=False).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type":"application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))

def ask(prompt, timeout=90):
    data = post(MINIMAX, {"goal": prompt}, timeout)
    if not data.get("ok"):
        raise RuntimeError(str(data.get("error") or "MiniMax failed"))
    return str(data.get("content") or "").strip()

def parse_json(text):
    text = text.strip()
    try:
        return json.loads(text)
    except Exception:
        pass
    s = min([x for x in [text.find("{"), text.find("[")] if x >= 0], default=-1)
    if s >= 0:
        for close in ["}", "]"]:
            e = text.rfind(close)
            if e > s:
                try:
                    return json.loads(text[s:e+1])
                except Exception:
                    pass
    raise RuntimeError("invalid model JSON")

def route(goal):
    skill = SKILL.read_text(encoding="utf-8", errors="ignore")[:3000]
    prompt = (
        "你是备用鸿蒙手机的Agent Runtime。当前安装的Skill如下：\n\n" + skill +
        "\n\n用户任务：\n" + goal +
        "\n\n如果任务要求在淘宝、天猫、京东搜索或比较商品价格，"
        '只返回严格JSON：{"action":"skill","skill":"shopping-compare","query":"商品搜索词"}。'
        '否则只返回严格JSON：{"action":"respond","text":"简短中文回答"}。'
    )
    obj = parse_json(ask(prompt, 60))
    if not isinstance(obj, dict):
        raise RuntimeError("router did not return object")
    return obj

def run_skill(query):
    p = subprocess.run(
        ["python3", RUNNER, "--query", query],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", errors="replace", timeout=120
    )
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout)[-1200:])
    return json.loads(p.stdout)

def summarize(goal, evidence):
    prompt = (
        "你是个人购物助理。以下证据来自备用Nova手机刚刚真实打开淘宝、天猫、京东App后的页面。\n\n"
        "用户任务：" + goal + "\n\n证据：" +
        json.dumps(evidence, ensure_ascii=False, separators=(",", ":")) +
        "\n\n请简洁总结三家当前可见的Mate 80价格和渠道。"
        "主表只列普通Mate 80；Mate 80 Pro和Pro Max若出现，只放在单独的备注里，不参与普通Mate 80价格推荐。"
        "不同内存、颜色、店铺和优惠条件不能假装成同一SKU。"
        "优先指出官方旗舰店或京东自营。可以指出当前页面样本的低价，但要明确配置可能不同。"
        "若页面同时显示多个价格且标签关系有歧义，只陈述可见价格，不要自行倒推。"
        "不要说已经下单。最后建议若要严格比价，应统一到同一存储配置。"
    )
    return ask(prompt, 75)

def execute(goal, task_id):
    decision = route(goal)
    if decision.get("action") != "skill":
        return {"ok":True, "taskId":task_id, "model":"MiniMax-M3",
                "skill":None, "content":str(decision.get("text") or "")}
    if decision.get("skill") != "shopping-compare":
        raise RuntimeError("skill not installed")
    query = str(decision.get("query") or "华为 Mate 80").strip()
    evidence = run_skill(query)
    content = summarize(goal, evidence)
    return {"ok":True, "taskId":task_id, "model":"MiniMax-M3",
            "skill":"shopping-compare", "query":query,
            "content":content, "evidence":evidence}

def execute_once(goal, task_id):
    if not task_id:
        return execute(goal, task_id)

    owner = False
    with TASK_LOCK:
        previous_goal = TASK_GOALS.get(task_id)
        if previous_goal is not None and previous_goal != goal:
            raise RuntimeError("taskId was reused with a different goal")
        TASK_GOALS[task_id] = goal

        if task_id in TASK_RESULTS:
            return TASK_RESULTS[task_id]
        if task_id in TASK_ERRORS:
            raise RuntimeError(TASK_ERRORS[task_id])

        event = TASK_EVENTS.get(task_id)
        if event is None:
            event = threading.Event()
            TASK_EVENTS[task_id] = event
            owner = True

    if not owner:
        if not event.wait(180):
            raise RuntimeError("timed out waiting for the original task execution")
        with TASK_LOCK:
            if task_id in TASK_RESULTS:
                return TASK_RESULTS[task_id]
            raise RuntimeError(TASK_ERRORS.get(task_id, "original task execution failed"))

    try:
        result = execute(goal, task_id)
        with TASK_LOCK:
            TASK_RESULTS[task_id] = result
            while len(TASK_RESULTS) > MAX_TASK_CACHE:
                oldest = next(iter(TASK_RESULTS))
                TASK_RESULTS.pop(oldest, None)
                TASK_ERRORS.pop(oldest, None)
                TASK_GOALS.pop(oldest, None)
        return result
    except Exception as exc:
        with TASK_LOCK:
            TASK_ERRORS[task_id] = str(exc)[:1000]
        raise
    finally:
        with TASK_LOCK:
            current = TASK_EVENTS.pop(task_id, None)
            if current is not None:
                current.set()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return
    def sendj(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == "/health":
            self.sendj(200, {"ok":True, "skills":["shopping-compare"]})
        else:
            self.sendj(404, {"ok":False, "error":"not found"})
    def do_POST(self):
        if self.path != "/execute":
            self.sendj(404, {"ok":False, "error":"not found"})
            return
        try:
            n = int(self.headers.get("Content-Length", "0"))
            data = json.loads(self.rfile.read(n) or b"{}")
            goal = str(data.get("goal") or "").strip()
            task_id = str(data.get("taskId") or "")
            if not goal:
                self.sendj(400, {"ok":False, "error":"goal required"})
                return
            print("execute start", task_id or "-", flush=True)
            result = execute_once(goal, task_id)
            print("execute done", task_id or "-", result.get("skill"), flush=True)
            self.sendj(200, result)
        except Exception as e:
            print("execute error", str(e)[:500], flush=True)
            self.sendj(502, {"ok":False, "error":str(e)[:1000]})

if __name__ == "__main__":
    host = os.getenv("HARMONY_AGENT_HOST", "127.0.0.1")
    port = int(os.getenv("HARMONY_AGENT_PORT", "8791"))
    print(f"Agent runtime listening on {host}:{port}", flush=True)
    ThreadingHTTPServer((host, port), Handler).serve_forever()
