## Latency & Buffer Controls

SoundMaxx uses a buffered audio pipeline to balance **latency (responsiveness)** and **stability (no crackles/dropouts)**. Understanding how this works helps you tune performance for your system.

### How the Buffers Work

There are three main parts to the buffering system:

1. **I/O Buffer (Device Buffer)**
   - This is the number of audio frames processed per callback by your audio device.
   - Lower values = lower latency, but higher CPU pressure.
   - Higher values = more stable, but increased delay.

2. **Ring Buffer (Internal Queue)**
   - A circular buffer that sits between input (BlackHole) and output.
   - It absorbs timing differences between input and output devices.
   - Prevents glitches when devices drift slightly out of sync.

3. **Latency Target (Queue Depth)**
   - Controls how much audio is allowed to accumulate in the ring buffer.
   - If the buffer grows too large, older audio is dropped to prevent delay buildup (A/V drift).

---

### The Trade-off

- **Lower latency** → more responsive audio, but risk of crackling
- **Higher buffering** → smoother playback, but noticeable delay

There is no perfect setting — it depends on your CPU, output device, and workload.

---

### Controls in the App

#### I/O Buffer
- Options: 64 → 4096 frames
- Controls how often audio is processed

**Guidelines:**
- 64–128 → ultra-low latency (may crackle)
- 256 → good default (balanced)
- 512–1024 → stable on slower systems

---

#### Ring Capacity
- Multiplier (1x → 16x) of the callback buffer size
- Defines total buffer space available before overflow

**Guidelines:**
- Lower = tighter, lower latency, but less tolerance for spikes
- Higher = more stable, but can allow latency to grow

---

#### Target Queue
- Multiplier (1x → ring capacity)
- Keeps the buffer near this size by trimming older frames

**Guidelines:**
- Lower = aggressive trimming → lower latency, more risk of dropouts
- Higher = smoother playback, but more delay

---

### Recommended Settings

**Balanced (default)**
- I/O Buffer: 256
- Ring Capacity: 4x
- Target Queue: 2x

**Low Latency (for monitoring / real-time work)**
- I/O Buffer: 64–128
- Ring Capacity: 2–4x
- Target Queue: 1–2x

**Maximum Stability (for weak systems or heavy load)**
- I/O Buffer: 512–1024
- Ring Capacity: 6–8x
- Target Queue: 3–4x

---

### Effective Values (Readout)

The app shows:

Effective: in Xf, out Yf, ring Zf


- **in** = actual input device buffer (may differ from requested)
- **out** = actual output device buffer
- **ring** = total internal buffer size

Devices may not support exact values — SoundMaxx automatically clamps to the nearest supported size.

---

### When to Adjust

- **Hearing crackles / pops** → increase I/O buffer or ring capacity
- **Audio feels delayed** → decrease I/O buffer or target queue
- **Audio slowly drifts out of sync** → lower target queue
- **Unstable when switching devices** → increase ring capacity

---

### Important Notes

- Changing these settings while running will briefly restart the audio engine.
- Extremely low settings may work on idle systems but fail under load.
- HDMI and Bluetooth devices often require higher buffer sizes for stability.