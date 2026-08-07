#!/usr/bin/env node
import { createApp } from "./src/ui.js";

createApp().catch((err) => {
  console.error("Failed to start SomaFM TUI:", err.message);
  process.exit(1);
});
