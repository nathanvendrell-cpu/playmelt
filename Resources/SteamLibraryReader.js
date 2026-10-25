// Valve's embedded games-list contract, before card filtering/virtualization:
// https://github.com/SteamDatabase/SteamTracking/blob/f63144369f9fd57b89ea583b44986182f175d671/c/steamcommunity.com/public/javascript/applications/community/games.js
// The reader returns only account ID, game IDs/names and provenance. It never
// reads cookies, tokens, card DOM, React internals or the deprecated XML endpoint.
return (() => {
  const source = "steamcommunity-profile-gameslist";
  const failure = status => ({ status });
  const validAccount = value => typeof value === "string" && /^[0-9]{17}$/.test(value);
  const location = new URL(window.location.href);
  if (location.protocol !== "https:" || location.hostname !== "steamcommunity.com" ||
      location.username || location.password || (location.port && location.port !== "443") ||
      !/^\/(profiles\/[0-9]{17}|id\/[^/]+)\/games\/?$/.test(location.pathname) ||
      location.searchParams.getAll("tab").length !== 1 ||
      location.searchParams.get("tab") !== "all") return failure("wrong-page");
  // Discovery is a separate native opt-in for a genuinely empty selection. An
  // invalid or changed selected account must never become implicit discovery.
  const discovering = typeof allowAccountDiscovery !== "undefined" &&
    allowAccountDiscovery === true && expectedAccountId === "";
  if (!validAccount(expectedAccountId) && !discovering) return failure("account-unselected");
  let viewer = typeof window.g_steamID === "string" ? window.g_steamID : "";
  const userInfoNode = document.getElementById("application_config");
  const userInfoRaw = userInfoNode?.getAttribute("data-userinfo");
  if (userInfoRaw) {
    if (userInfoRaw.length > 64000) return failure("identity-unverified");
    let user;
    try { user = JSON.parse(userInfoRaw); } catch { return failure("identity-unverified"); }
    if (user?.logged_in !== true) return failure("signed-out");
    if (!validAccount(user.steamid)) return failure("identity-unverified");
    if (viewer && viewer !== user.steamid) return failure("identity-mismatch");
    viewer = user.steamid;
  }
  if (!validAccount(viewer)) return failure("identity-unverified");
  if (!discovering && viewer !== expectedAccountId) return failure("account-mismatch");
  const raw = document.getElementById("gameslist_config")?.getAttribute("data-profile-gameslist");
  if (!raw) return failure("embedded-library-unavailable");
  if (raw.length > 8000000) return failure("too-large");
  let data;
  try { data = JSON.parse(raw); } catch { return failure("malformed-library"); }
  if (!data || data.strSteamId !== viewer || data.bViewingOwnProfile !== true)
    return failure("identity-mismatch");
  const urlOwner = location.pathname.match(/^\/profiles\/([0-9]{17})\/games\/?$/)?.[1];
  if (urlOwner && urlOwner !== viewer) return failure("identity-mismatch");
  if (!Array.isArray(data.rgGames)) return failure("embedded-library-unavailable");
  // The frontend fetches OwnedGames when this seed is empty; empty markup alone
  // cannot prove a genuinely empty account, nor overwrite an earlier snapshot.
  if (data.rgGames.length === 0) return failure("empty-unverified");
  if (data.rgGames.length >= 20000) return failure("too-large");
  const games = [], ids = new Set();
  for (const row of data.rgGames) {
    if (!row || typeof row !== "object" || Array.isArray(row)) return failure("malformed-library");
    if (typeof row.appid !== "number" && typeof row.appid !== "string") return failure("invalid-game");
    const rawID = String(row.appid);
    if (!/^[0-9]{1,10}$/.test(rawID)) return failure("invalid-game");
    const number = Number(rawID);
    if (!Number.isSafeInteger(number) || number < 1 || number > 4294967295) return failure("invalid-game");
    const appid = String(number);
    if (ids.has(appid)) return failure("duplicate-game");
    if (typeof row.name !== "string" || row.name.trim().length === 0) return failure("invalid-game");
    ids.add(appid); games.push({ appid, name: row.name.trim().slice(0, 200) });
  }
  return { status: "complete", source, accountId: viewer, games, count: games.length };
})();
