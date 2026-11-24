// Local prerecorded-audio probe. Model and feature conventions are from FluidVoice-Labs/fluid-speech-mini-onnx.
import * as ort from '/fluid-mini/ort.wasm.min.mjs';
const root = '/fluid-mini/';
ort.env.wasm.numThreads = 1;
ort.env.wasm.wasmPaths = new URL(root, location.href).href;

async function read(file, method) {
  const response = await fetch(root + file);
  if (!response.ok) throw new Error(file + ': ' + response.status);
  return response[method]();
}

async function loadModel() {
  const options = {executionProviders: ['wasm'], enableCpuMemArena: false, enableMemPattern: false};
  const load = (name, extra = {}) => ort.InferenceSession.create(root + name + '.onnx', {...options, ...extra});
  const config = await read('config.json', 'json');
  const tokenizer = await read('tokenizer.json', 'json');
  const pieces = [];
  for (const [word, id] of Object.entries(tokenizer.model.vocab)) pieces[id] = word;
  for (const item of tokenizer.added_tokens || []) pieces[item.id] = item.special ? '' : item.content;
  pieces[config.blank_token_id] = '';
  pieces[config.pad_token_id] = '';
  const buffer = await read('mel_filters.npy', 'arrayBuffer');
  const headerLength = new DataView(buffer).getUint16(8, true);
  const filters = new Float32Array(buffer, 10 + headerLength);
  const front = await load('frontend');
  const encoder = await load('encoder', {externalData: [{path: 'encoder.onnx.data', data: root + 'encoder.onnx.data'}]});
  const decoder = await load('decoder');
  const joint = await load('joint');
  return {config, filters, pieces, front, encoder, decoder, joint};
}

// Radix-2 FFT of one real, windowed frame, yielding the one-sided power spectrum.
function spectrum(real) {
  const n = real.length, imag = new Float64Array(n);
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) [real[i], real[j]] = [real[j], real[i]];
  }
  for (let width = 2; width <= n; width *= 2) {
    const half = width / 2;
    for (let k = 0; k < half; k++) {
      const angle = -2 * Math.PI * k / width, cos = Math.cos(angle), sin = Math.sin(angle);
      for (let i = k; i < n; i += width) {
        const j = i + half, r = real[j] * cos - imag[j] * sin, v = real[j] * sin + imag[j] * cos;
        real[j] = real[i] - r; imag[j] = imag[i] - v;
        real[i] += r; imag[i] += v;
      }
    }
  }
  return Float32Array.from(real.subarray(0, n / 2 + 1), (x, i) => x * x + imag[i] * imag[i]);
}

function features(samples, cfg, filters) {
  const {n_fft: n, hop_length: hop, win_length: win, num_mel_bins: bins} = cfg;
  const valid = Math.floor(samples.length / hop), frames = valid + 1, freqs = n / 2 + 1;
  if (valid < 2 || filters.length !== bins * freqs) throw new Error('Invalid audio or filter bank');
  const left = (n - win) / 2, values = new Float32Array(frames * bins);
  const window = Float32Array.from({length: win}, (_, i) => 0.5 - 0.5 * Math.cos(2 * Math.PI * i / (win - 1)));
  // Most mel weights are zero. Keep just the nonzero part of each triangular filter.
  const bands = Array.from({length: bins}, (_, i) => {
    const band = filters.subarray(i * freqs, (i + 1) * freqs);
    const first = band.findIndex(x => x !== 0);
    return {first, weights: band.slice(first, band.findLastIndex(x => x !== 0) + 1)};
  });
  for (let t = 0; t < valid; t++) {
    const frame = new Float64Array(n);
    for (let j = 0; j < win; j++) {
      const i = t * hop - n / 2 + left + j;
      if (i >= 0 && i < samples.length) frame[left + j] = (samples[i] - (i ? cfg.preemphasis * samples[i - 1] : 0)) * window[j];
    }
    const power = spectrum(frame);
    bands.forEach(({first, weights}, m) => {
      let energy = 0;
      for (let i = 0; i < weights.length; i++) energy += weights[i] * power[first + i];
      values[t * bins + m] = Math.log(energy + 2 ** -24);
    });
  }
  for (let m = 0; m < bins; m++) {
    let mean = 0, squares = 0;
    for (let t = 0; t < valid; t++) mean += values[t * bins + m];
    mean /= valid;
    for (let t = 0; t < valid; t++) squares += (values[t * bins + m] - mean) ** 2;
    const scale = Math.sqrt(squares / (valid - 1)) + 1e-5;
    for (let t = 0; t < valid; t++) values[t * bins + m] = (values[t * bins + m] - mean) / scale;
  }
  return {values, frames, valid, bins};
}

const floats = (data, dims) => new ort.Tensor('float32', data, dims);
const ints = (data, dims) => new ort.Tensor('int64', BigInt64Array.from(data, BigInt), dims);
async function run(session, feeds) {
  const out = await session.run(feeds);
  return session.outputNames.map(name => out[name]);
}

async function recognize(model, samples) {
  const {config: c, filters, front, encoder, decoder, joint, pieces} = model;
  if (samples.length > c.sampling_rate * c.max_single_pass_seconds) throw new Error('Clip exceeds one model pass');
  const {values, frames, valid, bins} = features(samples, c, filters);
  const factor = c.subsampling_stride ** c.subsampling_layers;
  const total = Math.ceil(frames / factor), length = Math.ceil(valid / factor), width = c.encoder_hidden_size;
  const hidden = new Float32Array(total * width);
  for (let a = 0; a < total; a += c.frontend_chunk_frames) {
    const b = Math.min(total, a + c.frontend_chunk_frames);
    const s = a ? factor * (a - 1) : 0, e = Math.min(frames, factor * (b + 1));
    const mask = new BigInt64Array(e - s).fill(1n, 0, Math.min(valid - s, e - s));
    const [part] = await run(front, {input_features: floats(values.subarray(s * bins, e * bins), [1, e - s, bins]),
      attention_mask: new ort.Tensor('int64', mask, [1, e - s])});
    const skip = a ? width : 0;
    hidden.set(part.data.subarray(skip, skip + (b - a) * width), a * width);
  }
  const [encoded] = await run(encoder, {hidden_states: floats(hidden, [1, total, width]), length: ints([length], [1])});
  const dims = [c.decoder_layers, 1, c.decoder_hidden_size];
  const zero = floats(new Float32Array(c.decoder_layers * c.decoder_hidden_size), dims);
  const decode = (id, h, state) => run(decoder, {token: ints([id], [1, 1]), h_in: h, c_in: state});
  let [output, h, state] = await decode(c.blank_token_id, zero, zero);
  const tokens = [], piecesWithConfidence = [];
  for (let t = 0; t < length && tokens.length < c.max_symbols_per_step * total - 1;) {
    const [scores] = await run(joint, {encoder_frame: floats(encoded.data.subarray(t * width, (t + 1) * width), [1, width]), decoder_out: output});
    const logits = scores.data, vocab = c.vocab_size;
    let token = 0, duration = 0;
    for (let i = 1; i < vocab; i++) if (logits[i] > logits[token]) token = i;
    for (let i = 1; i < c.durations.length; i++) if (logits[vocab + i] > logits[vocab + duration]) duration = i;
    tokens.push(token);
    if (token !== c.blank_token_id && pieces[token]) {
      let denominator = 0;
      for (let i = 0; i < vocab; i++) denominator += Math.exp(logits[i] - logits[token]);
      piecesWithConfidence.push({piece: pieces[token], confidence: 1 / denominator});
    }
    t += Math.max(token === c.blank_token_id ? 1 : 0, c.durations[duration]);
    if (token === c.eos_token_id || t >= length) break;
    if (token !== c.blank_token_id) [output, h, state] = await decode(token, h, state);
  }
  return {text: tokens.map(id => pieces[id] || '').join('').replaceAll('▁', ' ').trimStart(), pieces: piecesWithConfidence};
}

// Preparing during capture and recognizing at stop share one model initialization.
let loading;
export function warm() {
  return loading ??= loadModel();
}
export async function probe(samples, runs) {
  const start = performance.now();
  const model = await warm();
  const loadMs = Math.round(performance.now() - start), results = [];
  for (let i = 0; i < runs; i++) {
    const began = performance.now(), {text} = await recognize(model, samples);
    results.push({text, ms: Math.round(performance.now() - began)});
  }
  return {model: 'fluid-speech-mini-onnx', device: 'wasm', threads: 1, loadMs, audioSeconds: samples.length / 16000, results};
}

export async function transcribe(samples) {
  const model = await warm();
  return recognize(model, samples);
}
