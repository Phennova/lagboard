// LagBoard — effects engine.
// Runs in Google Meet's MAIN world at document_start. It wraps getUserMedia so the
// camera/mic tracks Meet receives are routed through a processing pipeline
// (MediaStreamTrackProcessor -> effects -> MediaStreamTrackGenerator).
// With no effects active, frames pass through untouched.
(() => {
  'use strict';
  if (window.__lagboardInstalled) return;
  window.__lagboardInstalled = true;

  const TAG = '[LagBoard]';
  const VIDEO_IDS = ['lowres', 'blocky', 'stutter', 'freeze', 'smear', 'glitch', 'lag', 'blackout'];
  const AUDIO_IDS = ['drop', 'robot', 'garble', 'achoppy', 'desync', 'mute'];

  const state = { active: new Set(), intensity: 0.7 };
  const live = { video: 0, audio: 0 };
  const supported =
    typeof window.MediaStreamTrackProcessor === 'function' &&
    typeof window.MediaStreamTrackGenerator === 'function';

  const on = (id) => state.active.has(id);
  const rand = (a, b) => a + Math.random() * (b - a);
  const randInt = (a, b) => Math.floor(rand(a, b + 1));
  const lerp = (a, b, t) => a + (b - a) * t;
  const now = () => performance.now();
  const chance = (p) => Math.random() < p;

  // ---------------------------------------------------------------- messaging
  window.addEventListener('message', (e) => {
    if (e.source !== window || !e.data || e.data.__lagboard !== 'state') return;
    const s = e.data.state || {};
    state.active = new Set(Array.isArray(s.active) ? s.active : []);
    if (typeof s.intensity === 'number') state.intensity = Math.max(0, Math.min(1, s.intensity));
  });

  function reportStatus() {
    window.postMessage(
      { __lagboard: 'status', video: live.video, audio: live.audio, supported },
      location.origin
    );
  }
  setInterval(reportStatus, 2000);

  // ---------------------------------------------------------------- track disguise
  // Make the processed track behave like the real camera/mic track to Meet.
  function disguise(out, src, onEnd) {
    for (const m of ['getSettings', 'getCapabilities', 'getConstraints', 'applyConstraints']) {
      if (typeof src[m] !== 'function') continue;
      try {
        Object.defineProperty(out, m, { value: (...a) => src[m](...a), configurable: true });
      } catch {}
    }
    try {
      Object.defineProperty(out, 'label', { get: () => src.label, configurable: true });
    } catch {}
    let ended = false;
    const finish = () => {
      if (ended) return;
      ended = true;
      onEnd();
    };
    const realStop = out.stop.bind(out);
    try {
      Object.defineProperty(out, 'stop', {
        value: () => {
          realStop();
          src.stop();
          finish();
        },
        configurable: true,
      });
    } catch {}
    src.addEventListener('ended', () => {
      try { realStop(); } catch {}
      finish();
    });
    return out;
  }

  // ================================================================ VIDEO
  // "Potato Res" runs every frame through a real VP8 encoder with a hard bitrate cap,
  // then decodes it. A moderate resolution with far too few bits gives the genuine
  // bad-Wi-Fi look: smudged "painted" texture, block edges, colour bleed, keyframe
  // "breathing" and a dropped frame rate — rather than a plain blur.
  const even = (n) => Math.max(16, Math.round(n / 2) * 2);
  class CrunchCodec {
    constructor() {
      this.enc = null;
      this.dec = null;
      this.latest = null;
      this.key = '';
      this.nextKey = 0;
      this.lastUse = 0;
      this.failed = typeof VideoEncoder !== 'function' || typeof VideoDecoder !== 'function';
      this.canvas = new OffscreenCanvas(16, 16);
      this.ctx = this.canvas.getContext('2d', { alpha: false });
      this.lastEncode = 0;
    }

    setup(cw, ch, bitrate) {
      this.stopCodecs();
      const dec = new VideoDecoder({
        output: (f) => {
          if (this.dec !== dec) return f.close();
          if (this.latest) this.latest.close();
          this.latest = f;
        },
        error: (e) => {
          console.warn(TAG, 'decoder', e);
          this.failed = true;
        },
      });
      const codec = 'vp8';
      dec.configure({ codec, codedWidth: cw, codedHeight: ch, optimizeForLatency: true });
      const enc = new VideoEncoder({
        output: (chunk) => {
          if (this.enc !== enc || dec.state !== 'configured') return;
          try { dec.decode(chunk); } catch {}
        },
        error: (e) => {
          console.warn(TAG, 'encoder', e);
          this.failed = true;
        },
      });
      enc.configure({ codec, width: cw, height: ch, framerate: 12, latencyMode: 'realtime', bitrateMode: 'constant', bitrate });
      this.enc = enc;
      this.dec = dec;
      this.nextKey = 0;
      this.canvas.width = cw;
      this.canvas.height = ch;
    }

    // Feeds one frame in; returns the most recent decoded (crunched) frame, or null.
    feed(source, ts, w, h, t, I) {
      if (this.failed) return null;
      this.lastUse = t;
      const cw = even(lerp(400, 640, I)); // more pixels per bit = more crunch
      const ch = even((cw * h) / w);
      const bitrate = Math.round(lerp(70, 20, I)) * 1000;
      const fps = lerp(18, 7, I); // low-bandwidth mode also sheds frame rate
      const key = `${cw}x${ch}@${bitrate}`;
      try {
        if (key !== this.key || !this.enc || this.enc.state !== 'configured') {
          this.key = key;
          this.setup(cw, ch, bitrate);
        }
        if (this.enc.encodeQueueSize <= 2 && (t - this.lastEncode >= 1000 / fps || !this.latest)) {
          this.lastEncode = t;
          this.ctx.drawImage(source, 0, 0, cw, ch);
          const vf = new VideoFrame(this.canvas, { timestamp: ts });
          const keyFrame = t > this.nextKey;
          if (keyFrame) this.nextKey = t + rand(2500, 6000);
          try { this.enc.encode(vf, { keyFrame }); } finally { vf.close(); }
        }
      } catch (e) {
        console.warn(TAG, 'codec unavailable, using fallback', e);
        this.failed = true;
        this.close();
        return null;
      }
      return this.latest;
    }

    stopCodecs() {
      for (const c of [this.enc, this.dec]) {
        try { if (c && c.state !== 'closed') c.close(); } catch {}
      }
      this.enc = null;
      this.dec = null;
    }

    close() {
      this.stopCodecs();
      this.key = '';
      if (this.latest) this.latest.close();
      this.latest = null;
    }
  }

  class VideoFX {
    constructor() {
      this.codec = new CrunchCodec();
      this.w = 0;
      this.h = 0;
      this.hasContent = false;
      this.nextStutter = 0;
      this.lagBuf = [];
      this.lastMotion = null;
      this.smearVec = [0, 0];
      this.smearVecUntil = 0;
      this.nextKeyframe = 0;
      this.glitch = null;
      this.blockEpoch = 0;
      this.blockSeed = 1;
    }

    ensure(w, h) {
      if (this.w === w && this.h === h) return;
      this.w = w;
      this.h = h;
      const mk = (cw, ch, opts) => {
        const c = new OffscreenCanvas(cw, ch);
        return [c, c.getContext('2d', { alpha: false, ...opts })];
      };
      [this.main, this.mx] = mk(w, h);
      [this.prev, this.px] = mk(w, h);
      [this.work, this.wx] = mk(w, h);
      [this.small, this.sx] = mk(16, 16);
      [this.tiny, this.tx] = mk(16, 16);
      [this.motion, this.motx] = mk(32, 18, { willReadFrequently: true });
      this.hasContent = false;
      this.lastMotion = null;
    }

    clearLag() {
      for (const b of this.lagBuf) b.close();
      this.lagBuf.length = 0;
    }

    async snapshot(frame) {
      return createImageBitmap(frame, {
        resizeWidth: Math.max(2, Math.round(this.w / 2)),
        resizeHeight: Math.max(2, Math.round(this.h / 2)),
        resizeQuality: 'low',
      });
    }

    async process(frame) {
      if (!on('lowres') && this.codec.enc && now() - this.codec.lastUse > 4000) this.codec.close();
      const anyOn = VIDEO_IDS.some(on) || this.lagBuf.length > 0;
      if (!anyOn) {
        this.hasContent = false;
        this.lastMotion = null;
        return frame; // untouched passthrough
      }
      const w = frame.displayWidth;
      const h = frame.displayHeight;
      this.ensure(w, h);
      const t = now();
      const I = state.intensity;

      // ---- lag spike: freeze while recording, then fast-forward through the backlog
      let source = frame;
      let replayBitmap = null;
      let hold = false;
      if (on('lag')) {
        if (this.lagBuf.length < 240) this.lagBuf.push(await this.snapshot(frame));
        hold = this.hasContent;
      } else if (this.lagBuf.length) {
        this.lagBuf.push(await this.snapshot(frame));
        const speed = 3; // play the backlog at 3x until caught up
        for (let i = 0; i < speed - 1 && this.lagBuf.length > 1; i++) this.lagBuf.shift().close();
        replayBitmap = this.lagBuf.shift();
        source = replayBitmap;
        if (this.lagBuf.length <= 1) this.clearLag();
      }

      if (on('freeze')) hold = hold || this.hasContent;

      // ---- choppy frame rate: hold frames for random intervals, with occasional hitches
      if (on('stutter') && !hold && this.hasContent) {
        if (t < this.nextStutter) hold = true;
        else {
          const hitch = chance(0.12) ? rand(500, 1300) * (0.4 + I) : 0;
          this.nextStutter = t + rand(70, 110 + 420 * I) + hitch;
        }
      }

      try {
        if (on('blackout')) {
          this.mx.fillStyle = '#000';
          this.mx.fillRect(0, 0, w, h);
          this.hasContent = false; // so Freeze afterwards holds a real frame, not black
        } else if (!hold || !this.hasContent) {
          this.render(source, w, h, t, I, frame.timestamp);
        }
        return new VideoFrame(this.main, { timestamp: frame.timestamp, alpha: 'discard' });
      } finally {
        if (replayBitmap) replayBitmap.close();
      }
    }

    render(source, w, h, t, I, ts) {
      const { wx, mx } = this;
      const needPrev = this.hasContent && (on('smear') || on('glitch'));
      if (needPrev) this.px.drawImage(this.main, 0, 0);

      // ---- 1. degrade into `work`: low-bitrate codec crunch + macroblocking
      const crunched = on('lowres') ? this.codec.feed(source, ts, w, h, t, I) : null;
      if (crunched) {
        wx.imageSmoothingEnabled = true;
        wx.imageSmoothingQuality = 'high';
        wx.drawImage(crunched, 0, 0, w, h);
        if (on('blocky')) this.macroblocks(source, w, h, t, I);
      } else if (on('lowres') || on('blocky')) {
        // fallback (codec warming up / unavailable): plain low-res upscale
        const f = on('lowres') ? lerp(3, 6, I) : 2.2;
        const sw = Math.max(16, Math.round(w / f));
        const sh = Math.max(9, Math.round(h / f));
        if (this.small.width !== sw || this.small.height !== sh) {
          this.small.width = sw;
          this.small.height = sh;
        }
        this.sx.imageSmoothingEnabled = true;
        this.sx.imageSmoothingQuality = 'medium';
        this.sx.drawImage(source, 0, 0, sw, sh);
        wx.imageSmoothingEnabled = true;
        wx.imageSmoothingQuality = 'high';
        wx.drawImage(this.small, 0, 0, w, h);
        if (on('blocky')) this.macroblocks(source, w, h, t, I);
      } else {
        wx.drawImage(source, 0, 0, w, h);
      }

      // ---- 2. compose into `main`, optionally with motion smearing (packet loss on P-frames)
      mx.drawImage(this.work, 0, 0);
      if (on('smear') && this.hasContent) this.smear(source, w, h, t, I);
      else this.lastMotion = null;

      // ---- 3. decode corruption bursts
      if (on('glitch') && this.hasContent) this.corrupt(w, h, t, I);
      else this.glitch = null;

      this.hasContent = true;
    }

    // Blocks with flat colour, like an encoder starved of bitrate.
    macroblocks(source, w, h, t, I) {
      const B = Math.max(8, Math.round((lerp(10, 22, I) * w) / 1280) * 2);
      const cols = Math.ceil(w / B);
      const rows = Math.ceil(h / B);
      if (this.tiny.width !== cols || this.tiny.height !== rows) {
        this.tiny.width = cols;
        this.tiny.height = rows;
      }
      this.tx.imageSmoothingEnabled = true;
      this.tx.drawImage(source, 0, 0, cols, rows);
      if (t > this.blockEpoch) {
        this.blockEpoch = t + rand(180, 650);
        this.blockSeed = (Math.random() * 1e9) | 0;
      }
      const p = lerp(0.12, 0.42, I);
      const path = new Path2D();
      const seed = this.blockSeed;
      for (let by = 0; by < rows; by++) {
        for (let bx = 0; bx < cols; bx++) {
          // Coherent-ish noise: neighbouring blocks tend to share fate.
          const n = hash(bx >> 1, by >> 1, seed) * 0.6 + hash(bx, by, seed + 7) * 0.4;
          if (n < p) path.rect(bx * B, by * B, B, B);
        }
      }
      const wx = this.wx;
      wx.save();
      wx.clip(path);
      wx.imageSmoothingEnabled = false;
      wx.globalAlpha = lerp(0.6, 0.9, I); // let a little detail bleed through, like real DCT blocks
      wx.drawImage(this.tiny, 0, 0, cols * B, rows * B);
      wx.globalAlpha = 1;
      wx.restore();
      wx.imageSmoothingEnabled = true;
    }

    // Moving regions drag stale pixels along instead of updating — the classic
    // "melting face" look when a reference frame is lost.
    smear(source, w, h, t, I) {
      const { motx, mx } = this;
      motx.drawImage(source, 0, 0, 32, 18);
      const d = motx.getImageData(0, 0, 32, 18).data;
      const lum = new Uint8Array(32 * 18);
      for (let i = 0; i < lum.length; i++) lum[i] = (d[i * 4] * 3 + d[i * 4 + 1] * 6 + d[i * 4 + 2]) / 10;
      const last = this.lastMotion;
      this.lastMotion = lum;
      if (!last) return;

      if (t > this.nextKeyframe) {
        // a fresh keyframe arrives: picture snaps back to clean for this frame
        this.nextKeyframe = t + rand(1200, 3800) * (0.5 + I);
        return;
      }
      if (t > this.smearVecUntil) {
        this.smearVecUntil = t + rand(300, 1100);
        const s = lerp(2, 9, I) * (w / 1280);
        this.smearVec = [rand(-s, s), rand(-s * 0.3, s * 1.2)];
      }
      const GX = 32;
      const GY = 18;
      const bw = w / GX;
      const bh = h / GY;
      const thr = lerp(16, 7, I);
      const refresh = lerp(0.12, 0.03, I);
      for (let gy = 0; gy < GY; gy++) {
        for (let gx = 0; gx < GX; gx++) {
          const i = gy * GX + gx;
          if (Math.abs(lum[i] - last[i]) < thr || chance(refresh)) continue;
          const x = gx * bw;
          const y = gy * bh;
          const jx = this.smearVec[0] + rand(-1, 1);
          const jy = this.smearVec[1] + rand(-1, 1);
          mx.drawImage(this.prev, x - jx, y - jy, bw + 1, bh + 1, x, y, bw + 1, bh + 1);
        }
      }
    }

    // Short bursts of partially-decoded frames: grey/green fill, smeared last row,
    // torn bands, shuffled blocks.
    corrupt(w, h, t, I) {
      const { mx } = this;
      if (!this.glitch || t > this.glitch.until) {
        this.glitch = null;
        if (!chance(lerp(0.03, 0.14, I))) return;
        const kinds = ['grey', 'green', 'streak', 'streak', 'tear', 'shuffle'];
        this.glitch = {
          kind: kinds[randInt(0, kinds.length - 1)],
          until: t + rand(120, 260 + 600 * I),
          y0: Math.round(h * rand(0.25, 0.85)),
          band: [Math.round(h * rand(0, 0.7)), Math.round(h * rand(0.05, 0.3))],
          shift: Math.round(w * rand(0.04, 0.22) * (chance(0.5) ? 1 : -1)),
        };
      }
      const g = this.glitch;
      const B = Math.max(8, Math.round(w / 40));
      switch (g.kind) {
        case 'grey':
        case 'green': {
          mx.fillStyle = g.kind === 'grey' ? '#808080' : '#008a45';
          mx.fillRect(0, g.y0, w, h - g.y0);
          // ragged edge where decoding stopped
          for (let x = 0; x < w; x += B) if (chance(0.5)) mx.fillRect(x, g.y0 - B, B, B);
          break;
        }
        case 'streak': {
          // the last decoded row gets stretched down the rest of the frame
          mx.drawImage(this.prev, 0, g.y0 - 2, w, 2, 0, g.y0, w, h - g.y0);
          break;
        }
        case 'tear': {
          const [by, bhh] = g.band;
          mx.drawImage(this.prev, 0, by, w, bhh, g.shift, by, w, bhh);
          break;
        }
        case 'shuffle': {
          const n = Math.round(lerp(8, 50, I));
          for (let i = 0; i < n; i++) {
            const sx = randInt(0, Math.floor(w / B)) * B;
            const sy = randInt(0, Math.floor(h / B)) * B;
            const dx = randInt(0, Math.floor(w / B)) * B;
            const dy = randInt(0, Math.floor(h / B)) * B;
            mx.drawImage(this.prev, sx, sy, B * 2, B, dx, dy, B * 2, B);
          }
          break;
        }
      }
    }
  }

  function hash(x, y, s) {
    let n = (x * 374761393 + y * 668265263 + s * 2147483647) | 0;
    n = Math.imul(n ^ (n >>> 13), 1274126177);
    return ((n ^ (n >>> 16)) >>> 0) / 4294967296;
  }

  function wrapVideoTrack(src) {
    const proc = new MediaStreamTrackProcessor({ track: src });
    const gen = new MediaStreamTrackGenerator({ kind: 'video' });
    const fx = new VideoFX();
    live.video++;
    reportStatus();
    proc.readable
      .pipeThrough(
        new TransformStream({
          async transform(frame, ctl) {
            let out = frame;
            try {
              out = await fx.process(frame);
            } catch (err) {
              console.warn(TAG, 'video fx error', err);
              out = frame;
            }
            ctl.enqueue(out);
            if (out !== frame) frame.close();
          },
        })
      )
      .pipeTo(gen.writable)
      .catch(() => {});
    return disguise(gen, src, () => {
      fx.clearLag();
      fx.codec.close();
      live.video = Math.max(0, live.video - 1);
      reportStatus();
    });
  }

  // ================================================================ AUDIO
  // Processes audio in 20 ms "packets" (like Opus) so losses and concealment
  // happen at realistic granularity.
  class AudioFX {
    init(sr, C) {
      this.sr = sr;
      this.C = C;
      this.ringLen = Math.ceil(sr * 2.5);
      this.ring = Array.from({ length: C }, () => new Float32Array(this.ringLen));
      this.w = 0;
      this.P = Math.round(sr * 0.02);
      this.pi = 0;
      this.cur = Array.from({ length: C }, () => new Float32Array(this.P));
      this.good = Array.from({ length: C }, () => new Float32Array(this.P));
      this.rep = Array.from({ length: C }, () => new Float32Array(this.P * 4));
      this.repLen = 1;
      this.repPos = 0;
      this.mode = 'ok';
      this.prevMode = 'ok';
      this.left = 0;
      this.lostRun = 0;
      this.period = Math.round(sr / 200);
      this.delay = 0;
      this.gate = 1;
      this.gain = 1;
      this.hv = new Float32Array(C);
      this.lp = new Float32Array(C);
      this.holdCnt = 0;
      this.smooth = 1 / (0.004 * sr);
    }

    boundary() {
      const I = state.intensity;
      if (this.mode === 'ok') {
        const t = this.good;
        this.good = this.cur;
        this.cur = t;
      }
      this.prevMode = this.mode;

      // lip desync: growing the delay inserts a gap (like a jitter buffer stall)
      const targetDelay = on('desync') ? Math.round(this.sr * lerp(0.3, 0.85, I)) : 0;
      if (targetDelay > this.delay) {
        const grow = targetDelay - this.delay;
        this.delay = targetDelay;
        this.mode = 'gap';
        this.left = Math.ceil(grow / this.P) - 1;
        return;
      }
      if (targetDelay < this.delay) this.delay = targetDelay;

      if (this.mode === 'gap' && !on('drop') && !on('desync')) this.left = 0;
      if (this.mode === 'repeat' && !on('achoppy')) this.left = 0;
      if (this.left > 0) {
        this.left--;
        return;
      }

      this.mode = 'ok';
      if (on('drop') && chance(lerp(0.025, 0.09, I))) {
        this.mode = 'gap';
        this.left = randInt(4, Math.round(10 + 32 * I)) - 1;
      } else if (on('achoppy') && chance(lerp(0.05, 0.14, I))) {
        this.mode = 'repeat';
        this.captureRepeat(3);
        this.left = 3 * randInt(2, 4) - 1;
      } else if (on('robot')) {
        const p = this.prevMode === 'lost' ? lerp(0.5, 0.82, I) : lerp(0.15, 0.45, I);
        if (chance(p)) {
          this.mode = 'lost';
          if (this.prevMode !== 'lost') {
            this.lostRun = 0;
            this.period = Math.round(this.sr / rand(110, 260));
          }
          this.lostRun++;
        }
      }
    }

    captureRepeat(packets) {
      const len = this.P * packets;
      this.repLen = len;
      this.repPos = 0;
      for (let ch = 0; ch < this.C; ch++) {
        const ring = this.ring[ch];
        for (let i = 0; i < len; i++) {
          let r = this.w - this.delay - len + i;
          r = ((r % this.ringLen) + this.ringLen) % this.ringLen;
          this.rep[ch][i] = ring[r];
        }
      }
    }

    // in: array of Float32Array per channel. Returns true if output differs from input.
    run(inp, out, n) {
      const I = state.intensity;
      const garble = on('garble');
      const D = Math.round(lerp(2, 7, I));
      const q = Math.pow(2, Math.round(lerp(7, 3.5, I)));
      const lpA = lerp(0.35, 0.12, I);
      const muteTarget = on('mute') ? 0 : 1;
      const { C, P, ringLen } = this;
      for (let i = 0; i < n; i++) {
        if (this.pi === 0) this.boundary();
        const gateTarget = this.mode === 'gap' ? 0 : 1;
        this.gate += (gateTarget - this.gate) * this.smooth;
        this.gain += (muteTarget - this.gain) * this.smooth;
        const lostGain = this.mode === 'lost' ? Math.pow(0.86, this.lostRun - 1) : 1;
        let r = this.w - this.delay;
        if (r < 0) r += ringLen;
        const sh = this.holdCnt === 0;
        for (let ch = 0; ch < C; ch++) {
          const x = inp[ch][i];
          this.ring[ch][this.w] = x;
          const liveS = this.ring[ch][r];
          let y;
          switch (this.mode) {
            case 'ok':
              y = liveS;
              this.cur[ch][this.pi] = liveS;
              break;
            case 'lost': {
              const per = Math.min(this.period, P);
              y = this.good[ch][P - per + (this.pi % per)] * lostGain;
              break;
            }
            case 'repeat':
              y = this.rep[ch][this.repPos % this.repLen];
              break;
            default:
              y = 0;
          }
          if (garble) {
            if (sh) this.hv[ch] = y;
            y = Math.round(this.hv[ch] * q) / q;
            this.lp[ch] += lpA * (y - this.lp[ch]);
            y = this.lp[ch] * 1.25;
          }
          y *= this.gate * this.gain;
          out[ch][i] = y > 1 ? 1 : y < -1 ? -1 : y;
        }
        this.w = (this.w + 1) % ringLen;
        this.repPos++;
        this.holdCnt = (this.holdCnt + 1) % D;
        if (++this.pi >= P) this.pi = 0;
      }
      return !(
        !AUDIO_IDS.some(on) &&
        this.delay === 0 &&
        this.mode === 'ok' &&
        this.gate > 0.999 &&
        this.gain > 0.999
      );
    }

    process(ad) {
      const C = ad.numberOfChannels;
      const n = ad.numberOfFrames;
      if (this.sr !== ad.sampleRate || this.C !== C) this.init(ad.sampleRate, C);
      const data = new Float32Array(n * C);
      const inp = [];
      const out = [];
      for (let ch = 0; ch < C; ch++) {
        const view = data.subarray(ch * n, (ch + 1) * n);
        ad.copyTo(view, { planeIndex: ch, format: 'f32-planar' });
        inp.push(view.slice());
        out.push(view);
      }
      const changed = this.run(inp, out, n);
      if (!changed) return ad; // bit-exact passthrough when idle
      return new AudioData({
        format: 'f32-planar',
        sampleRate: ad.sampleRate,
        numberOfFrames: n,
        numberOfChannels: C,
        timestamp: ad.timestamp,
        data,
      });
    }
  }

  function wrapAudioTrack(src) {
    const proc = new MediaStreamTrackProcessor({ track: src });
    const gen = new MediaStreamTrackGenerator({ kind: 'audio' });
    const fx = new AudioFX();
    live.audio++;
    reportStatus();
    proc.readable
      .pipeThrough(
        new TransformStream({
          transform(ad, ctl) {
            let out = ad;
            try {
              out = fx.process(ad);
            } catch (err) {
              console.warn(TAG, 'audio fx error', err);
              out = ad;
            }
            ctl.enqueue(out);
            if (out !== ad) ad.close();
          },
        })
      )
      .pipeTo(gen.writable)
      .catch(() => {});
    return disguise(gen, src, () => {
      live.audio = Math.max(0, live.audio - 1);
      reportStatus();
    });
  }

  // ================================================================ hook
  if (!supported) {
    console.warn(TAG, 'Insertable streams unavailable; effects disabled.');
    reportStatus();
    return;
  }

  function wrapStream(stream) {
    const tracks = stream.getTracks().map((t) => {
      try {
        if (t.kind === 'video') return wrapVideoTrack(t);
        if (t.kind === 'audio') return wrapAudioTrack(t);
      } catch (err) {
        console.warn(TAG, 'could not wrap track', err);
      }
      return t;
    });
    return new MediaStream(tracks);
  }

  const proto = MediaDevices.prototype;
  const realGUM = proto.getUserMedia;
  const patched = {
    getUserMedia(constraints) {
      return realGUM.call(this, constraints).then((stream) => {
        try {
          return wrapStream(stream);
        } catch (err) {
          console.warn(TAG, err);
          return stream;
        }
      });
    },
  }.getUserMedia;
  Object.defineProperty(patched, 'toString', { value: () => realGUM.toString() });
  proto.getUserMedia = patched;
  reportStatus();
})();
