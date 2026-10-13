// Converts the microphone to 24 kHz mono PCM16 blocks of 20 ms while "on".
class PcmProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.block = new Int16Array(480);
    this.filled = 0;
    this.on = false;
    this.port.onmessage = (event) => {
      if (event.data === "on") {
        this.on = true;
      } else if (event.data === "off") {
        this.on = false;
        if (this.filled > 0) {
          this.port.postMessage({ audio: this.block.slice(0, this.filled).buffer });
          this.filled = 0;
        }
        this.port.postMessage({ flushed: true });
      }
    };
  }

  process(inputs) {
    const channel = inputs[0] && inputs[0][0];
    if (!channel || !this.on) return true;
    for (let i = 0; i < channel.length; i += 1) {
      const s = Math.max(-1, Math.min(1, channel[i]));
      this.block[this.filled++] = s < 0 ? s * 0x8000 : s * 0x7fff;
      if (this.filled === this.block.length) {
        this.port.postMessage({ audio: this.block.slice().buffer });
        this.filled = 0;
      }
    }
    return true;
  }
}
registerProcessor("pcm-processor", PcmProcessor);
