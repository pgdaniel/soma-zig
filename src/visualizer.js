export class Visualizer {
  constructor(parent, opts = {}) {
    this.parent = parent;
    this.left = opts.left ?? 0;
    this.top = opts.top ?? 0;
    this.width = opts.width ?? 40;
    this.height = opts.height ?? 10;
    this.bars = opts.bars ?? 32;
    this.running = false;
    this.timer = null;
    this.values = new Array(this.bars).fill(0);
    this.targets = new Array(this.bars).fill(0);
    this.pattern = opts.pattern ?? "waves";
    this.barChars = opts.barChars ?? ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"];
    this.colors = opts.colors ?? [
      "{cyan-fg}",
      "{blue-fg}",
      "{magenta-fg}",
      "{red-fg}",
      "{yellow-fg}",
      "{green-fg}",
    ];
    this.colorIndex = 0;
    this.frameCount = 0;
  }

  start() {
    this.running = true;
    this.tick();
  }

  stop() {
    this.running = false;
    if (this.timer) clearTimeout(this.timer);
    this.values = new Array(this.bars).fill(0);
  }

  tick() {
    if (!this.running) return;
    this.generateTargets();
    this.smoothValues();
    this.render();
    this.frameCount++;
    this.timer = setTimeout(() => this.tick(), 80);
  }

  generateTargets() {
    const t = this.frameCount * 0.15;

    for (let i = 0; i < this.bars; i++) {
      let val;

      switch (this.pattern) {
        case "waves":
          val = (Math.sin(t + i * 0.3) * 0.5 + 0.5) * (Math.sin(i * 0.5 + t * 0.7) * 0.5 + 0.7);
          break;
        case "pulse":
          val = Math.abs(Math.sin(t - i * 0.15)) * (0.4 + Math.sin(i * 0.4) * 0.3);
          break;
        case "bars":
          val = Math.abs(Math.sin(t * 1.3 + i * 0.25)) * (0.3 + Math.random() * 0.7);
          break;
        case "spectrum":
          const bass = Math.sin(t * 0.8) * 0.5 + 0.5;
          const mid = Math.sin(t * 1.5 + i * 0.2) * 0.4 + 0.4;
          val = i < this.bars * 0.25 ? bass * (1 - i / (this.bars * 0.25)) * 0.8
              : i < this.bars * 0.6 ? mid * 0.6
              : mid * (1 - (i - this.bars * 0.6) / (this.bars * 0.4)) * 0.4;
          break;
        default:
          val = Math.abs(Math.sin(t + i * 0.2)) * (0.3 + Math.random() * 0.4);
      }

      val = Math.max(0.05, Math.min(1, val + Math.random() * 0.1));
      this.targets[i] = val;
    }
  }

  smoothValues() {
    const speed = 0.3;
    for (let i = 0; i < this.bars; i++) {
      this.values[i] += (this.targets[i] - this.values[i]) * speed;
    }
  }

  render() {
    if (this.colorIndex % 8 === 0) {
      this.currentColor = this.colors[Math.floor(Math.random() * this.colors.length)];
    }
    this.colorIndex++;

    const color = this.currentColor || "{cyan-fg}";

    const rows = [];
    for (let row = 0; row < this.height; row++) {
      let line = "";
      const threshold = 1 - row / (this.height - 1 || 1);
      for (let i = 0; i < this.bars; i++) {
        const barH = this.values[i] * this.height;
        const barPos = barH - row;
        if (barPos >= 0.9) line += `${color}█{/}`;
        else if (barPos >= 0.75) line += `${color}▇{/}`;
        else if (barPos >= 0.5) line += `${color}▅{/}`;
        else if (barPos >= 0.25) line += `${color}▃{/}`;
        else if (barPos > 0) line += `${color}▁{/}`;
        else line += " ";
      }
      rows.push(line);
    }

    const out = rows.join("\n");

    if (this.parent.setContent) {
      this.parent.setContent(out);
    } else {
      process.stdout.write(`\x1b[${this.top + 1};${this.left + 1}H`);
      process.stdout.write(out);
    }
    if (this.parent.screen) {
      this.parent.screen.render();
    }
  }
}
