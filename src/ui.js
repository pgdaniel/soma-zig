import blessed from "blessed";
import { fetchChannels, formatChannel } from "./channels.js";
import { play, stop, getState, setVolume } from "./player.js";
import { Visualizer } from "./visualizer.js";

const VISUALIZER_PATTERNS = ["waves", "pulse", "bars", "spectrum"];

export async function createApp() {
  const screen = blessed.screen({
    smartCSR: true,
    title: "SomaFM TUI",
    fullUnicode: true,
  });

  const header = blessed.box({
    top: 0,
    left: 0,
    width: "100%",
    height: 3,
    content: "",
    tags: true,
    style: {
      fg: "white",
      bg: "black",
    },
  });

  const channelList = blessed.list({
    top: 3,
    left: 0,
    width: "60%",
    height: "100%-5",
    label: " SomaFM Channels ",
    keys: true,
    vi: true,
    mouse: true,
    scrollbar: {
      ch: " ",
      track: { bg: "cyan" },
      style: { inverse: true },
    },
    tags: true,
    border: { type: "line" },
    style: {
      fg: "white",
      bg: "black",
      border: { fg: "cyan" },
      selected: { bg: "cyan", fg: "black", bold: true },
      item: { fg: "white", bg: "black" },
    },
  });

  const infoBox = blessed.box({
    top: 3,
    left: "60%",
    width: "40%",
    height: 8,
    label: " Now Playing ",
    tags: true,
    border: { type: "line" },
    style: {
      fg: "white",
      bg: "black",
      border: { fg: "magenta" },
    },
  });

  const vizBox = blessed.box({
    top: 11,
    left: "60%",
    width: "40%",
    height: "100%-13",
    label: " Visualizer ",
    tags: true,
    border: { type: "line" },
    style: {
      fg: "white",
      bg: "black",
      border: { fg: "green" },
    },
  });

  const statusBar = blessed.box({
    bottom: 0,
    left: 0,
    width: "100%",
    height: 1,
    tags: true,
    style: {
      fg: "black",
      bg: "cyan",
    },
  });

  screen.append(header);
  screen.append(channelList);
  screen.append(infoBox);
  screen.append(vizBox);
  screen.append(statusBar);

  let channels = [];
  let currentViz = null;
  let volume = 80;

  function updateHeader() {
    header.setContent(
      "{center}{bold}{cyan-fg}╔══════════════════════════════════════════╗{/}\n" +
        "{center}{bold}{cyan-fg}║{/}      {white-fg}S  O  M  A  F  M{/}         {cyan-fg}║{/}\n" +
        "{center}{bold}{cyan-fg}║{/}  {green-fg}Internet Radio Visualizer{/}     {cyan-fg}║{/}\n" +
        "{center}{bold}{cyan-fg}╚══════════════════════════════════════════╝{/}"
    );
  }

  function updateInfo(channel) {
    if (!channel) {
      infoBox.setContent(
        "\n{center}{gray-fg}Select a channel to play{/}"
      );
      return;
    }
    infoBox.setContent(
      ` {cyan-fg}Channel:{/} {bold}${channel.title}{/}\n` +
        ` {cyan-fg}Genre:{/}   ${channel.genre || "N/A"}\n` +
        ` {cyan-fg}DJ:{/}      ${channel.dj || "None"}\n` +
        ` {cyan-fg}Listeners:{/} ${channel.listeners}\n` +
        ` {cyan-fg}Now:{/}     ${channel.lastPlaying || "Loading..."}\n` +
        ` {cyan-fg}Volume:{/}   ${volume}%`
    );
  }

  function updateStatus(msg) {
    statusBar.setContent(
      ` {black-fg}{cyan-bg} ${msg} {/} | {bold}↑↓{/}nav {bold}Enter{/}play {bold}s{/}stop {bold}+/-{/}vol {bold}v{/}viz {bold}q{/}quit`
    );
  }

  function startVisualizer() {
    const width = Math.floor((Number(vizBox.width) || 40) - 2);
    const height = Math.floor((Number(vizBox.height) || 10) - 2);

    if (currentViz) currentViz.stop();

    currentViz = new Visualizer(vizBox, {
      bars: Math.max(16, Math.min(64, width)),
      height: Math.max(4, height),
      pattern: VISUALIZER_PATTERNS[Math.floor(Math.random() * VISUALIZER_PATTERNS.length)],
    });
    currentViz.start();
  }

  function cycleVizPattern() {
    if (!currentViz) return;
    const idx = VISUALIZER_PATTERNS.indexOf(currentViz.pattern);
    currentViz.pattern = VISUALIZER_PATTERNS[(idx + 1) % VISUALIZER_PATTERNS.length];
  }

  async function loadChannels() {
    updateStatus("Loading channels from SomaFM...");
    screen.render();

    try {
      channels = await fetchChannels();
      updateStatus(`${channels.length} channels loaded`);

      channelList.setItems(
        channels.map((ch, i) => formatChannel(ch, (Number(channelList.width) || 80) - 4))
      );

      if (channels.length > 0) {
        channelList.select(0);
        updateInfo(channels[0]);
      }
    } catch (err) {
      updateStatus(`Error loading channels: ${err.message}`);
    }
    screen.render();
  }

  function playChannel(channel) {
    const urls = channel.urls;
    if (!urls || urls.length === 0) {
      updateStatus(`No stream URL for ${channel.title}`);
      screen.render();
      return;
    }

    updateStatus(`Tuning in: ${channel.title}`);
    updateInfo(channel);
    screen.render();

    try {
      stop();
      startVisualizer();

      play(urls[0], channel, (meta) => {
        if (meta) {
          channel.lastPlaying = meta;
          updateInfo(channel);
          screen.render();
        }
      });

      updateStatus(`Now playing: ${channel.title}`);
    } catch (err) {
      updateStatus(`Playback error: ${err.message}`);
    }
    screen.render();
  }

  function stopPlayback() {
    stop();
    if (currentViz) currentViz.stop();
    updateStatus("Stopped");
    infoBox.setContent("\n{center}{gray-fg}Playback stopped{/}");
    screen.render();
  }

  function adjustVolume(delta) {
    volume = Math.max(0, Math.min(100, volume + delta));
    try { setVolume(volume); } catch (e) { /* ignore */ }
    const state = getState();
    if (state.playing && state.channel) {
      updateInfo(state.channel);
    }
    updateStatus(`Volume: ${volume}%`);
    screen.render();
  }

  screen.key(["q", "C-c"], () => {
    stopPlayback();
    screen.destroy();
    process.exit(0);
  });

  screen.key(["enter", "space"], () => {
    const idx = channelList.selected;
    if (idx !== undefined && channels[idx]) {
      playChannel(channels[idx]);
    }
  });

  screen.key(["s", "S"], () => stopPlayback());

  screen.key(["+", "="], () => adjustVolume(5));
  screen.key(["-", "_"], () => adjustVolume(-5));

  screen.key(["v", "V"], () => {
    if (currentViz && getState().playing) {
      cycleVizPattern();
      updateStatus(`Visualizer: ${currentViz.pattern}`);
      screen.render();
    }
  });

  channelList.on("select", (item, idx) => {
    if (channels[idx]) {
      playChannel(channels[idx]);
    }
  });

  channelList.on("select item", (item, idx) => {
    if (channels[idx]) {
      updateInfo(channels[idx]);
      screen.render();
    }
  });

  screen.key(["up", "k"], () => {
    channelList.up(1);
    const idx = channelList.selected;
    if (idx !== undefined && channels[idx]) {
      updateInfo(channels[idx]);
      screen.render();
    }
  });

  screen.key(["down", "j"], () => {
    channelList.down(1);
    const idx = channelList.selected;
    if (idx !== undefined && channels[idx]) {
      updateInfo(channels[idx]);
      screen.render();
    }
  });

  screen.on("resize", () => {
    channelList.setItems(
      channels.map((ch) => formatChannel(ch, (Number(channelList.width) || 80) - 4))
    );
    if (currentViz && getState().playing) {
      const width = Math.floor((Number(vizBox.width) || 40) - 2);
      const height = Math.floor((Number(vizBox.height) || 10) - 2);
      currentViz.width = width;
      currentViz.height = height;
      currentViz.bars = Math.max(16, Math.min(64, width));
      currentViz.values = new Array(currentViz.bars).fill(0);
      currentViz.targets = new Array(currentViz.bars).fill(0);
    }
    screen.render();
  });

  updateHeader();
  updateStatus("Loading SomaFM channels...");
  await loadChannels();
  startVisualizer();

  screen.render();
  return screen;
}
