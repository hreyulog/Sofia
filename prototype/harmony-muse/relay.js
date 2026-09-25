const http = require('http');

const queues = { primary: [], executor: [] };
const AGENT_RUNTIME = process.env.HARMONY_AGENT_URL || 'http://127.0.0.1:8791/execute';
const completedTasks = new Set();

function log(...x) {
  console.log(new Date().toISOString(), ...x);
}

function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body)
  });
  res.end(body);
}

async function readJson(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const raw = Buffer.concat(chunks).toString('utf8');
  return { raw, data: JSON.parse(raw || '{}') };
}

async function callPlanner(goal, taskId) {
  const response = await fetch(AGENT_RUNTIME, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ goal, taskId })
  });
  const data = await response.json();
  if (!response.ok || !data.ok) {
    throw new Error(String(data.error || ('HTTP ' + response.status)));
  }
  return {
    model: String(data.model || 'MiniMax-M3'),
    content: String(data.content || '')
  };
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://127.0.0.1');

  if (req.method === 'GET' && u.pathname === '/health') {
    return send(res, 200, { ok: true });
  }

  if (req.method === 'GET' && u.pathname === '/poll') {
    const role = u.searchParams.get('role');
    if (!(role in queues)) {
      return send(res, 400, { ok: false, error: 'bad role' });
    }
    const msg = queues[role].shift() || null;
    log('POLL', role, '=>', msg ? (msg.type + ' ' + msg.id) : 'empty');
    return send(res, 200, { ok: true, message: msg });
  }

  if (req.method === 'POST' && u.pathname === '/send') {
    try {
      const { raw, data } = await readJson(req);
      log('POST /send', 'from=', data.from, 'to=', data.to,
        'type=', data.type, 'id=', data.id, 'bytes=', Buffer.byteLength(raw));

      if (!(data.to in queues)) {
        return send(res, 400, { ok: false, error: 'bad role' });
      }

      const msg = {
        id: String(data.id || Date.now()),
        from: String(data.from || ''),
        to: data.to,
        type: String(data.type || 'msg'),
        payload: data.payload ?? null,
        ts: Date.now()
      };
      if (
        completedTasks.has(msg.id) &&
        (msg.type === 'TASK_COMPLETED' || msg.type === 'TASK_FAILED')
      ) {
        log('SUPPRESS late terminal message', msg.type, msg.id);
        return send(res, 200, { ok: true, accepted: msg.id, duplicate: true });
      }
      if (msg.type === 'TASK_COMPLETED') {
        completedTasks.add(msg.id);
      }
      queues[data.to].push(msg);
      return send(res, 200, { ok: true, accepted: msg.id });
    } catch (e) {
      return send(res, 400, { ok: false, error: 'bad json' });
    }
  }

  if (req.method === 'POST' && u.pathname === '/llm') {
    try {
      const { data } = await readJson(req);
      const goal = String(data.goal || '').trim();
      const taskId = String(data.taskId || '');
      if (!goal) return send(res, 400, { ok: false, error: 'goal required' });

      log('AGENT start', taskId || '-', 'goal_chars=', goal.length);
      const result = await callPlanner(goal, taskId);
      log('AGENT done', taskId || '-', 'model=', result.model, 'chars=', result.content.length);

      if (taskId && result.content && !completedTasks.has(taskId)) {
        const completion = {
          id: taskId,
          from: 'executor',
          to: 'primary',
          type: 'TASK_COMPLETED',
          payload: JSON.stringify({
            summary: result.content,
            model: result.model || 'MiniMax-M3'
          }),
          ts: Date.now()
        };
        completedTasks.add(taskId);
        queues.primary.push(completion);
        log('QUEUE TASK_COMPLETED', taskId, 'for primary');
      } else if (taskId && result.content) {
        log('SUPPRESS duplicate AGENT completion', taskId);
      }

      return send(res, 200, {
        ok: true,
        taskId,
        model: result.model,
        content: result.content
      });
    } catch (e) {
      log('LLM error', String(e && e.message ? e.message : e));
      return send(res, 502, {
        ok: false,
        error: String(e && e.message ? e.message : e)
      });
    }
  }

  send(res, 404, { ok: false, error: 'not found' });
});

const RELAY_HOST = process.env.HARMONY_RELAY_HOST || '127.0.0.1';
const RELAY_PORT = Number(process.env.HARMONY_RELAY_PORT || '8787');
server.listen(RELAY_PORT, RELAY_HOST, () => {
  log('relay listening', RELAY_HOST + ':' + RELAY_PORT);
});
