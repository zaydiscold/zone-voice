import {transcribe} from '/fluid-mini/fluid-mini.js';
async function loadWav(url) {
  const buffer = await (await fetch(url)).arrayBuffer();
  const view = new DataView(buffer);
  let offset = 12, rate = 16000, channels = 1, bits = 16;
  while (offset + 8 <= view.byteLength) {
    const id = String.fromCharCode(view.getUint8(offset), view.getUint8(offset + 1), view.getUint8(offset + 2), view.getUint8(offset + 3));
    const size = view.getUint32(offset + 4, true);
    if (id === 'fmt ') {
      channels = view.getUint16(offset + 10, true);
      rate = view.getUint32(offset + 12, true);
      bits = view.getUint16(offset + 22, true);
    } else if (id === 'data') {
      if (bits !== 16) throw new Error('expected 16-bit PCM, got ' + bits);
      const count = Math.floor(Math.min(size, view.byteLength - offset - 8) / 2 / channels);
      const mono = new Float32Array(count);
      for (let i = 0; i < count; i++) mono[i] = view.getInt16(offset + 8 + i * 2 * channels, true) / 32768;
      return { samples: resample(mono, rate, 16000), seconds: count / rate };
    }
    offset += 8 + size + (size % 2);
  }
  throw new Error('no data chunk in ' + url);
}

function resample(samples, from, to) {
  if (from === to) return samples;
  const ratio = from / to;
  const out = new Float32Array(Math.floor(samples.length / ratio));
  for (let i = 0; i < out.length; i++) {
    const start = Math.floor(i * ratio), end = Math.min(samples.length, Math.floor((i + 1) * ratio));
    let sum = 0;
    for (let j = start; j < end; j++) sum += samples[j];
    out[i] = sum / Math.max(1, end - start);
  }
  return out;
}

export async function run() {
  const audio = await loadWav('/audio.wav');
  // Match Zone's native SilenceTrimmer at 16 kHz, including its 300 ms margins.
  let samples = audio.samples;
  if (samples.length > 1280) {
    const frame = 320, energy = [], margin = 4800;
    for (let start = 0; start < samples.length; start += frame) {
      const end = Math.min(start + frame, samples.length);
      let sum = 0;
      for (let i = start; i < end; i++) sum += samples[i] * samples[i];
      energy.push(Math.sqrt(sum / (end - start)));
    }
    const peak = Math.max(...energy);
    if (!peak) return {text: '', pieces: []};
    const first = energy.findIndex(value => value >= peak * 0.05);
    const last = energy.findLastIndex(value => value >= peak * 0.05);
    samples = samples.subarray(Math.max(0, first * frame - margin), Math.min(samples.length, (last + 1) * frame + margin));
  }
  if (samples.length < 16000) {
    const padded = new Float32Array(16000);
    padded.set(samples);
    samples = padded;
  }
  return transcribe(samples);
}
