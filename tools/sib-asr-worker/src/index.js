// 感知有度 Sense in Balance：連網時的語音辨識中繼（Hybrid AI 雲端增強）
// App 只送一次錄音；這裡同時送台語（Breeze-ASR-26 / RunPod）與華語（Groq Whisper），
// 再用一個很短的判斷挑出「像車內需求」的那一段。金鑰只存在 Worker secrets，不進 App。
const JUDGE_PROMPT = `兩段文字是同一段車內語音的辨識結果：A 來自台語辨識模型，B 來自華語辨識模型。
說話者可能講台語或華語。選出比較像一句通順、有意義的車內需求的那一段。
只輸出 JSON：{"pick":"A"} 或 {"pick":"B"}。`;

function b64(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

// 1 秒靜音，只用來把 RunPod 叫醒（冷啟動約 40 秒）。
const SILENCE_M4A = "AAAAHGZ0eXBNNEEgAAACAE00QSBpc29taXNvMgAAAAhmcmVlAAAAXW1kYXTeAgBMYXZjNjIuMjEuMTAwAAIwQA4BGCAHARggBwEYIAcBGCAHARggBwEYIAcBGCAHARggBwEYIAcBGCAHARggBwEYIAcBGCAHARggBwEYIAcBGCAHAAADPm1vb3YAAABsbXZoZAAAAAAAAAAAAAAAAAAAA+gAAAPoAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAJpdHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAQAAAAAAAAPoAAAAAAAAAAAAAAABAQAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAAD6AAABAAAAQAAAAAB4W1kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAAPoAAAEKAVcQAAAAAAC1oZGxyAAAAAAAAAABzb3VuAAAAAAAAAAAAAAAAU291bmRIYW5kbGVyAAAAAYxtaW5mAAAAEHNtaGQAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAVBzdGJsAAAAanN0c2QAAAAAAAAAAQAAAFptcDRhAAAAAAAAAAEAAAAAAAAAAAABABAAAAAAPoAAAAAAADZlc2RzAAAAAAOAgIAlAAEABICAgBdAFQAAAAAAXcAAAAJ/BYCAgAUUCFblAAaAgIABAgAAACBzdHRzAAAAAAAAAAIAAAAQAAAEAAAAAAEAAAKAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAARAAAAAQAAAFhzdHN6AAAAAAAAAAAAAAARAAAAFQAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAUc3RjbwAAAAAAAAABAAAALAAAABpzZ3BkAQAAAHJvbGwAAAACAAAAAf//AAAAHHNiZ3AAAAAAcm9sbAAAAAEAAAARAAAAAQAAAGF1ZHRhAAAAWW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3QAAAAkqXRvbwAAABxkYXRhAAAAAQAAAABMYXZmNjIuNi4xMDM=";
const BREEZE_TIMEOUT_MS = 8000;

async function breeze(env, bytes) {
  const t = Date.now();
  // 台語那一路最多等 8 秒；冷啟動時先回華語結果，不讓台上卡住。
  const r = await fetch(`https://api.runpod.ai/v2/${env.RUNPOD_ENDPOINT_ID}/runsync`, {
    signal: AbortSignal.timeout(BREEZE_TIMEOUT_MS),
    method: "POST",
    headers: { Authorization: `Bearer ${env.RUNPOD_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ input: { audio_base64: b64(bytes) } }),
  });
  const d = await r.json();
  if (d.status !== "COMPLETED") throw new Error(`breeze ${d.status}`);
  return { text: (d.output?.text || "").trim(), ms: Date.now() - t, delay: d.delayTime, exec: d.executionTime };
}

async function groq(env, bytes) {
  const t = Date.now();
  const form = new FormData();
  form.append("file", new Blob([bytes], { type: "audio/mp4" }), "utterance.m4a");
  form.append("model", "whisper-large-v3");
  form.append("language", "zh");
  form.append("response_format", "json");
  const r = await fetch("https://api.groq.com/openai/v1/audio/transcriptions", {
    method: "POST", headers: { Authorization: `Bearer ${env.GROQ_API_KEY}` }, body: form,
  });
  if (!r.ok) throw new Error(`groq ${r.status}`);
  const d = await r.json();
  return { text: (d.text || "").trim(), ms: Date.now() - t };
}

async function judge(env, a, b) {
  const r = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${env.OPENROUTER_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "google/gemini-3.1-flash-lite", temperature: 0, max_tokens: 20,
      provider: { zdr: true, data_collection: "deny" }, reasoning: { enabled: false },
      messages: [{ role: "system", content: JUDGE_PROMPT }, { role: "user", content: `A：${a}\nB：${b}` }],
    }),
  });
  const d = await r.json();
  const content = d.choices?.[0]?.message?.content || "";
  return /"pick"\s*:\s*"A"/.test(content) ? "A" : "B";
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (req.headers.get("x-sib-token") !== env.APP_TOKEN) return new Response("forbidden", { status: 403 });
    if (url.pathname === "/warm") {
      // 送一個非同步工作把 RunPod 叫醒，不等結果；同時回報目前狀態。
      const auth = { Authorization: `Bearer ${env.RUNPOD_API_KEY}`, "Content-Type": "application/json" };
      await fetch(`https://api.runpod.ai/v2/${env.RUNPOD_ENDPOINT_ID}/run`, {
        method: "POST", headers: auth, body: JSON.stringify({ input: { audio_base64: SILENCE_M4A } }),
      });
      const h = await fetch(`https://api.runpod.ai/v2/${env.RUNPOD_ENDPOINT_ID}/health`, { headers: auth });
      return Response.json({ ok: true, health: await h.json() });
    }
    if (url.pathname !== "/asr" || req.method !== "POST") return new Response("not found", { status: 404 });
    const bytes = new Uint8Array(await req.arrayBuffer());
    if (bytes.length < 1000 || bytes.length > 2_000_000) return new Response("bad audio", { status: 400 });
    const t = Date.now();
    const [tw, zh] = await Promise.allSettled([breeze(env, bytes), groq(env, bytes)]);
    const A = tw.status === "fulfilled" ? tw.value : null;
    const B = zh.status === "fulfilled" ? zh.value : null;
    let pick = null;
    if (A?.text && B?.text) pick = await judge(env, A.text, B.text);
    else if (A?.text) pick = "A";
    else if (B?.text) pick = "B";
    if (!pick) return Response.json({ ok: false, error: "no_transcript" }, { status: 502 });
    const chosen = pick === "A" ? A : B;
    return Response.json({
      ok: true,
      text: chosen.text,
      lang: pick === "A" ? "nan" : "zh",
      candidates: { taigi: A?.text ?? null, mandarin: B?.text ?? null },
      timing_ms: { total: Date.now() - t, taigi: A?.ms ?? null, mandarin: B?.ms ?? null },
      taigi_error: tw.status === "rejected" ? String(tw.reason?.name || tw.reason) : null,
    });
  },
};
