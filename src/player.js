import { spawn } from "child_process";

let currentProcess = null;
let onTrackChange = null;
let playerState = { playing: false, channel: null };

function cleanup() {
  if (currentProcess) {
    currentProcess.kill("SIGKILL");
    currentProcess = null;
  }
  playerState.playing = false;
  playerState.channel = null;
}

process.once("SIGINT", () => { cleanup(); process.exit(0); });
process.once("SIGTERM", () => { cleanup(); process.exit(0); });
process.on("exit", cleanup);

export function play(url, channel, metadataCallback) {
  stop();

  onTrackChange = metadataCallback;
  playerState = { playing: true, channel };

  const proc = spawn("mpv", [
    "--no-video",
    "--really-quiet",
    "--volume=80",
    "--audio-buffer=0.5",
    "--cache=yes",
    "--cache-secs=2",
    url,
  ]);

  currentProcess = proc;

  proc.stdout?.on("data", (data) => {
    const output = data.toString();
    if (onTrackChange) onTrackChange(output);
  });

  proc.stderr?.on("data", (data) => {
    const output = data.toString();
    const titleMatch = output.match(/icy-title:\s*(.+)/i);
    if (titleMatch && onTrackChange) {
      onTrackChange(titleMatch[1].trim());
    }
    const nameMatch = output.match(/icy-name:\s*(.+)/i);
    if (nameMatch && onTrackChange) {
      onTrackChange(nameMatch[1].trim());
    }
  });

  proc.on("exit", () => {
    if (currentProcess === proc) {
      playerState.playing = false;
      playerState.channel = null;
      currentProcess = null;
    }
  });

  proc.on("error", (err) => {
    console.error("mpv error:", err.message);
    if (currentProcess === proc) {
      playerState.playing = false;
      currentProcess = null;
    }
  });

  return proc;
}

export function stop() {
  if (currentProcess) {
    currentProcess.kill("SIGKILL");
    currentProcess = null;
    playerState.playing = false;
    playerState.channel = null;
  }
}

export function getState() {
  return { ...playerState };
}

export function setVolume(vol) {
  if (currentProcess && currentProcess.stdin) {
    currentProcess.stdin.write(`set volume ${vol}\n`);
  }
}
