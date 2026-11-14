import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const PROMPT = [
  "You are a meeting minutes assistant.",
  "Return strict JSON with keys: transcript, summary, decisions, actions, risks.",
  "actions is an array of {task, owner, due}.",
  "Use the same language as the meeting. Do not invent facts.",
  "If multiple speakers can be distinguished, label them as Speaker 1/2/3 in the transcript; keep real names when the ASR provides them.",
  "Only output JSON, no Markdown."
].join(" ");

function json(data, status) {
  return new Response(JSON.stringify(data), {
    status: status || 200,
    headers: Object.assign({ "Content-Type": "application/json" }, cors),
  });
}

function parseJson(text) {
  const raw = String(text || "").trim();
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start >= 0 && end > start) {
    try { return JSON.parse(raw.slice(start, end + 1)); } catch (e) {}
  }
  return null;
}

async function gemini(audio, mime, ai) {
  const key = (ai && ai.gemini_key) || Deno.env.get("GEMINI_API_KEY") || "";
  if (!key) throw new Error("GEMINI_API_KEY is not configured");
  const model = (ai && ai.gemini_model) || Deno.env.get("GEMINI_MODEL") || "gemini-2.5-flash";
  const base = "https://generativelanguage.googleapis.com/v1beta";
  let part;
  if (audio.byteLength <= 18 * 1024 * 1024) {
    let binary = "";
    const chunk = 0x8000;
    for (let i = 0; i < audio.length; i += chunk) {
      binary += String.fromCharCode.apply(null, audio.subarray(i, i + chunk));
    }
    part = { inline_data: { mime_type: mime, data: btoa(binary) } };
  } else {
    const upload = await fetch(base + "/files?key=" + encodeURIComponent(key), {
      method: "POST",
      headers: {
        "Content-Type": mime,
        "X-Goog-Upload-Protocol": "raw",
        "X-Goog-Upload-Header-Content-Type": mime,
      },
      body: audio,
    });
    if (!upload.ok) throw new Error("Gemini file upload failed: " + upload.status);
    const file = await upload.json();
    part = { file_data: { mime_type: mime, file_uri: file.uri } };
  }
  const response = await fetch(
    base + "/models/" + model + ":generateContent?key=" + encodeURIComponent(key),
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [{ parts: [part, { text: PROMPT }] }],
        generationConfig: { responseMimeType: "application/json" },
      }),
    }
  );
  if (!response.ok) throw new Error("Gemini summary failed: " + response.status);
  const data = await response.json();
  const parts = data.candidates?.[0]?.content?.parts || [];
  const text = parts.map(function (p) { return p.text || ""; }).join("");
  const parsed = parseJson(text);
  if (!parsed) throw new Error("Gemini returned invalid JSON");
  return parsed;
}

async function domestic(audio, mime, ai) {
  const cfg = ai || {};
  const asrUrl = cfg.asr_url || Deno.env.get("DOMESTIC_ASR_URL") || "";
  const asrKey = cfg.asr_key || Deno.env.get("DOMESTIC_ASR_KEY") || "";
  const llmUrl = cfg.llm_url || Deno.env.get("DOMESTIC_LLM_URL") || "";
  const llmKey = cfg.llm_key || Deno.env.get("DOMESTIC_LLM_KEY") || "";
  const llmModel = cfg.llm_model || Deno.env.get("DOMESTIC_LLM_MODEL") || "deepseek-chat";
  if (!asrUrl || !llmUrl) throw new Error("domestic ASR/LLM is not configured");
  const asrHeaders = { "Content-Type": mime };
  if (asrKey) asrHeaders.Authorization = "Bearer " + asrKey;
  const asr = await fetch(asrUrl, { method: "POST", headers: asrHeaders, body: audio });
  if (!asr.ok) throw new Error("ASR failed: " + asr.status);
  const asrData = await asr.json();
  const transcript = String(asrData.text || (asrData.result && asrData.result.text) || "");
  if (!transcript) throw new Error("ASR returned no text");
  const llmHeaders = { "Content-Type": "application/json" };
  if (llmKey) llmHeaders.Authorization = "Bearer " + llmKey;
  const llm = await fetch(llmUrl, {
    method: "POST",
    headers: llmHeaders,
    body: JSON.stringify({
      model: llmModel,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: PROMPT },
        { role: "user", content: transcript.slice(0, 50000) },
      ],
    }),
  });
  if (!llm.ok) throw new Error("LLM failed: " + llm.status);
  const llmData = await llm.json();
  const choice = llmData.choices?.[0]?.message?.content || "";
  const parsed = parseJson(choice);
  if (!parsed) throw new Error("LLM returned invalid JSON");
  parsed.transcript = parsed.transcript || transcript;
  return parsed;
}

Deno.serve(async function (request) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const auth = request.headers.get("Authorization") || "";
    if (auth.indexOf("Bearer ") !== 0) return json({ error: "missing auth" }, 401);
    const body = await request.json();
    const meetingId = String(body.meeting_id || "");
    const audioPath = String(body.audio_path || "");
    if (!meetingId || !audioPath) {
      return json({ error: "meeting_id and audio_path required" }, 400);
    }
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") || "",
      Deno.env.get("SUPABASE_ANON_KEY") || "",
      { global: { headers: { Authorization: auth } } }
    );
    const download = await supabase.storage.from("meeting-audio").download(audioPath);
    if (download.error || !download.data) throw new Error("audio download failed");
    const audio = new Uint8Array(await download.data.arrayBuffer());
    const mime = body.mime_type || download.data.type || "audio/webm";
    let ai = body.ai || {};
    if (!ai.gemini_key && !ai.asr_url) {
      try {
        const service = createClient(
          Deno.env.get("SUPABASE_URL") || "",
          Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || ""
        );
        const { data: meeting } = await service
          .from("meetings").select("enterprise_id").eq("id", meetingId).maybeSingle();
        if (meeting && meeting.enterprise_id) {
          const { data: companyAi } = await service.rpc("get_meeting_ai_secrets", {
            p_enterprise: meeting.enterprise_id,
          });
          if (companyAi) ai = companyAi;
        }
      } catch (_) {}
    }
    const provider = ai.provider || Deno.env.get("MEETING_AI_PROVIDER") || "gemini";
    let result;
    try {
      result = provider === "domestic" ? await domestic(audio, mime, ai) : await gemini(audio, mime, ai);
    } catch (primaryError) {
      result = provider === "domestic" ? await gemini(audio, mime, ai) : await domestic(audio, mime, ai);
    }
    const update = await supabase.rpc("update_meeting_summary", {
      p_meeting: meetingId,
      p_transcript: result.transcript || "",
      p_summary: result.summary || "",
      p_decisions: result.decisions || [],
      p_actions: result.actions || [],
      p_risks: result.risks || [],
    });
    if (update.error) throw update.error;
    await supabase.storage.from("meeting-audio").remove([audioPath]);
    return json(Object.assign({ ok: true }, result));
  } catch (error) {
    return json({ error: String(error && error.message || error) }, 500);
  }
});
