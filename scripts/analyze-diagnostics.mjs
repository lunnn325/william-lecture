// Usage: node scripts/analyze-diagnostics.mjs path/to/diagnostics.jsonl
// No transcript text or API credentials are needed for latency statistics.
import { readFileSync } from 'node:fs';
const input = process.argv[2];
if (!input) { console.error('Pass an exported diagnostics.jsonl path.'); process.exit(1); }
const lines = readFileSync(input, 'utf8').split('\n');
if (lines.at(-1)?.trim()) lines.pop(); // ignore interrupted unterminated tail
const events = lines.filter(x => x.trim()).map(x => JSON.parse(x));
const stats = (event, field, excludeMock = false) => {
  const values = events.filter(e => e.event === event && (!excludeMock || e.fields?.mock === 'false'))
    .map(e => Number(e.fields?.[field])).filter(Number.isFinite).sort((a,b) => a-b);
  const percentile = p => values.length ? Math.round(values[Math.ceil(values.length*p)-1]) : null;
  return { count: values.length, p50_ms: percentile(.5), p95_ms: percentile(.95), max_ms: values.at(-1) ?? null };
};
const report = {
  note: 'Speech uses Apple audio ranges and local receipt times; this is not teacher-reference ground truth. Mock translations are excluded. First Speech result is measured per analyzer run.',
  first_english_from_range_start: stats('speech_first_result', 'range_start_to_receipt_ms'),
  partial_english_after_range_end: stats('speech_partial', 'end_to_receipt_ms'),
  stable_english_after_range_end: stats('speech_finalized', 'end_to_receipt_ms'),
  buffer_after_final_receipt: stats('buffer_emit', 'english_final_to_emit_ms'),
  first_chinese_after_speech_end: stats('translation_first_result', 'speech_end_to_first_ms', true),
  stable_chinese_after_speech_end: stats('translation_completed', 'speech_end_to_complete_ms', true),
  gpt_request_to_first: stats('translation_first_result', 'request_ms', true),
  gpt_request_to_complete: stats('translation_completed', 'request_ms', true),
  gaps_and_errors: events.filter(e => e.fields?.gap || e.event.endsWith('_error')).map(({ at,event,offset,fields }) => ({ at,event,offset,fields })),
  peak_resident_MB: Math.round(Math.max(0,...events.filter(e=>e.event==='health').map(e=>Number(e.fields?.resident_bytes)||0))/1048576),
  max_audio_MB: Math.round(Math.max(0,...events.filter(e=>e.event==='health').map(e=>Number(e.fields?.audio_bytes)||0))/1048576),
  counts: Object.fromEntries([...new Set(events.map(e=>e.event))].map(event=>[event,events.filter(e=>e.event===event).length]))
};
console.log(JSON.stringify(report,null,2));
