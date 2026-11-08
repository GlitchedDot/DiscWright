// ATRAC encode worker.
//
// One Wasm instance of the atracdenc encoder per worker. app.js
// runs a pool of these, sized from navigator.hardwareConcurrency,
// and feeds each worker one track's interleaved int16 PCM at a
// time. The glue (atrac3p.js) is a MODULARIZE build that supports
// worker environments and finds its .wasm next to this script.

importScripts("atrac3p.js");

let mod = null;
const ready = (async () => {
  try {
    mod = await Atrac3p({});
    self.postMessage({ type: "ready" });
  } catch (err) {
    self.postMessage({
      type: "initError",
      error: String((err && err.message) || err),
    });
  }
})();

self.onmessage = async (e) => {
  const { id, pcm, perChannel } = e.data;
  try {
    await ready;
    if (!mod) throw new Error("encoder failed to start");
    const pcm16 = new Int16Array(pcm);
    const ctx = mod._atrac3p_create(2);
    if (!ctx) throw new Error("encoder create failed");
    const buf = mod._malloc(pcm16.length * 2);
    mod.HEAP16.set(pcm16, buf / 2);
    const rc = mod._atrac3p_encode(ctx, buf, perChannel);
    if (rc !== 0) {
      mod._atrac3p_destroy(ctx);
      mod._free(buf);
      throw new Error("encode failed");
    }
    const outLen = mod._atrac3p_flush(ctx);
    const frames = new Uint8Array(
      mod.HEAPU8.buffer, mod._atrac3p_output(ctx), outLen).slice();
    mod._atrac3p_destroy(ctx);
    mod._free(buf);
    self.postMessage({ id, ok: true, frames: frames.buffer }, [frames.buffer]);
  } catch (err) {
    self.postMessage({
      id, ok: false, error: String((err && err.message) || err),
    });
  }
};
