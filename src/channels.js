const SOMA_API = "https://somafm.com/channels.json";

export async function fetchChannels() {
  const res = await fetch(SOMA_API);
  if (!res.ok) throw new Error(`SomaFM API error: ${res.status}`);
  const data = await res.json();
  return data.channels.map((ch) => ({
    id: ch.id,
    title: ch.title,
    description: ch.description,
    genre: ch.genre,
    dj: ch.dj || "",
    listeners: ch.listeners || "?",
    lastPlaying: ch.lastPlaying || "",
    urls: ch.playlists
      .filter((p) => p.format === "mp3" && p.quality === "highest")
      .map((p) => p.url),
    image: ch.image,
  }));
}

export function formatChannel(channel, width) {
  const listeners = String(channel.listeners).padStart(4);
  const genre = (channel.genre || "").slice(0, 15).padEnd(15);
  const dj = channel.dj ? ` [${channel.dj}]` : "";
  const title = channel.title + dj;
  const remaining = width - listeners.length - genre.length - 4;
  return `${listeners} ${genre} ${title.slice(0, Math.max(0, remaining - 1))}`;
}
