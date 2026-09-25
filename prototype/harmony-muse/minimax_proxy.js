const fs = require('fs');
const http = require('http');
const path = require('path');

const TOKEN_PATH = process.env.MINIMAX_TOKEN_FILE || path.join(__dirname, 'minimaxtoken.txt');
const MODEL = process.env.MINIMAX_MODEL || 'MiniMax-M3';
const API_URL = process.env.MINIMAX_API_URL || 'https://api.minimaxi.com/v1/text/chatcompletion_v2';

function readToken() {
  return fs.readFileSync(TOKEN_PATH, 'utf8').trim();
}

function json(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body)
  });
  res.end(body);
}

async function callMiniMax(goal) {
  const token = readToken();
  const response = await fetch(API_URL, {
    method: 'POST',
    headers: {
      'authorization': 'Bearer ' + token,
      'content-type': 'application/json'
    },
    body: JSON.stringify({
      model: MODEL,
      messages: [
        {
          role: 'system',
          content: 'You are the planner for a spare-phone personal assistant. Respond in concise Chinese. For this MVP, produce a short actionable plan and a final user-facing summary. Do not claim to have executed actions you did not execute.'
        },
        {
          role: 'user',
          content: goal
        }
      ]
    })
  });

  const raw = await response.text();
  let data;
  try {
    data = JSON.parse(raw);
  } catch (_) {
    throw new Error('MiniMax returned non-JSON HTTP ' + response.status);
  }

  if (!response.ok) {
    const detail = data.base_resp || data.error || {};
    throw new Error('MiniMax HTTP ' + response.status + ': ' + JSON.stringify(detail));
  }

  if (data.base_resp && Number(data.base_resp.status_code || 0) !== 0) {
    throw new Error(
      'MiniMax API status ' + String(data.base_resp.status_code) +
      ': ' + String(data.base_resp.status_msg || data.base_resp.message || 'unknown')
    );
  }

  const choices = data.choices || [];
  let content = '';
  if (choices.length > 0) {
    const first = choices[0] || {};
    if (first.message) {
      if (typeof first.message.content === 'string') {
        content = first.message.content;
      } else if (Array.isArray(first.message.content)) {
        content = first.message.content
          .map(item => typeof item === 'string' ? item : String(item.text || item.content || ''))
          .join('');
      }
    }
    if (!content && typeof first.text === 'string') {
      content = first.text;
    }
  }

  if (!content) {
    const debug = {
      topLevelKeys: Object.keys(data),
      choiceCount: choices.length,
      firstChoiceKeys: choices.length ? Object.keys(choices[0] || {}) : [],
      firstMessageKeys: choices.length && choices[0].message
        ? Object.keys(choices[0].message)
        : [],
      baseResp: data.base_resp || null
    };
    throw new Error('MiniMax returned no assistant content: ' + JSON.stringify(debug));
  }

  return {
    model: MODEL,
    content,
    usage: data.usage || null
  };
}

async function callMiniMaxVision(prompt, imageBase64, mediaType) {
  const token = readToken();
  const response = await fetch(API_URL, {
    method: 'POST',
    headers: {
      'authorization': 'Bearer ' + token,
      'content-type': 'application/json'
    },
    body: JSON.stringify({
      model: MODEL,
      messages: [
        {
          role: 'user',
          content: [
            {
              type: 'text',
              text: prompt
            },
            {
              type: 'image_url',
              image_url: {
                url: 'data:' + mediaType + ';base64,' + imageBase64,
                detail: 'high'
              }
            }
          ]
        }
      ]
    })
  });

  const raw = await response.text();
  let data;
  try {
    data = JSON.parse(raw);
  } catch (_) {
    throw new Error('MiniMax vision returned non-JSON HTTP ' + response.status);
  }

  if (!response.ok) {
    const detail = data.base_resp || data.error || {};
    throw new Error('MiniMax vision HTTP ' + response.status + ': ' + JSON.stringify(detail));
  }
  if (data.base_resp && Number(data.base_resp.status_code || 0) !== 0) {
    throw new Error(
      'MiniMax vision API status ' + String(data.base_resp.status_code) +
      ': ' + String(data.base_resp.status_msg || data.base_resp.message || 'unknown')
    );
  }

  const choices = data.choices || [];
  if (!choices.length || !choices[0].message) {
    throw new Error('MiniMax vision returned no choices');
  }
  const content = choices[0].message.content;
  if (typeof content === 'string' && content.trim()) {
    return { model: MODEL, content };
  }
  if (Array.isArray(content)) {
    const text = content.map(x => typeof x === 'string' ? x : String(x.text || x.content || '')).join('');
    if (text.trim()) return { model: MODEL, content: text };
  }
  throw new Error('MiniMax vision returned no assistant text');
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');

  if (req.method === 'GET' && url.pathname === '/health') {
    return json(res, 200, { ok: true, model: MODEL });
  }

  if (req.method === 'POST' && url.pathname === '/plan') {
    let chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', async () => {
      try {
        const payload = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
        const goal = String(payload.goal || '').trim();
        if (!goal) return json(res, 400, { ok: false, error: 'goal required' });

        const result = await callMiniMax(goal);
        json(res, 200, { ok: true, ...result });
      } catch (err) {
        json(res, 502, {
          ok: false,
          error: err instanceof Error ? err.message : String(err)
        });
      }
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/vision') {
    let chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', async () => {
      try {
        const payload = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
        const prompt = String(payload.prompt || '').trim();
        const imageBase64 = String(payload.imageBase64 || '').trim();
        const mediaType = String(payload.mediaType || 'image/png');
        if (!prompt || !imageBase64) {
          return json(res, 400, { ok: false, error: 'prompt and imageBase64 required' });
        }
        const result = await callMiniMaxVision(prompt, imageBase64, mediaType);
        json(res, 200, { ok: true, ...result });
      } catch (err) {
        json(res, 502, {
          ok: false,
          error: err instanceof Error ? err.message : String(err)
        });
      }
    });
    return;
  }

  json(res, 404, { ok: false, error: 'not found' });
});

const HOST = process.env.MINIMAX_PROXY_HOST || '127.0.0.1';
const PORT = Number(process.env.MINIMAX_PROXY_PORT || '8790');
server.listen(PORT, HOST, () => {
  console.log('MiniMax proxy listening on ' + HOST + ':' + PORT + ' model=' + MODEL);
});
