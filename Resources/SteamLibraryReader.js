// Valve's embedded games-list contract, before card filtering/virtualization:
// https://github.com/SteamDatabase/SteamTracking/blob/f63144369f9fd57b89ea583b44986182f175d671/c/steamcommunity.com/public/javascript/applications/community/games.js
// The reader returns only account ID, game IDs/names and provenance. It never
// reads cookies, tokens, card DOM, React internals or the deprecated XML endpoint.
return (() => {
  const source = "steamcommunity-profile-gameslist";
  const failure = (status, reason) => reason ? { status, reason } : { status };
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
  function readDocument(rootDocument, globalViewer = "", globalUserConfig) {
  let viewer = typeof globalViewer === "string" ? globalViewer : "";
  let identityNodeSeen = false, userInfoSeen = false;
  // Valve's current WebUI config reader uses #webui_config. Legacy community
  // pages still use #application_config. Both are server-supplied identity
  // records; every record that is present must agree, never choose the one
  // that happens to match the selected account.
  // https://community.akamai.steamstatic.com/public/javascript/applications/community/main.js?contenthash=CFd3fnYH
  function acceptIdentity(user) {
    if (user?.logged_in !== true) {
      const reason = user?.logged_in === false ? "userinfo-not-signed-in" :
        user?.logged_in === "true" ? "logged-in-string-true" :
        user?.logged_in === "false" ? "logged-in-string-false" :
        user?.logged_in === "1" ? "logged-in-string-one" :
        user?.logged_in === "0" ? "logged-in-string-zero" :
        user?.logged_in === 1 ? "logged-in-number-one" :
        user?.logged_in === 0 ? "logged-in-number-zero" :
        typeof user?.logged_in === "string" ? "logged-in-string" :
        typeof user?.logged_in === "number" ? "logged-in-number" : "logged-in-unavailable";
      return failure("signed-out", reason);
    }
    if (!validAccount(user.steamid)) return failure("identity-unverified",
      typeof user.steamid === "number" ? "userinfo-id-number" :
      typeof user.steamid === "string" ? "userinfo-id-invalid" : "userinfo-id-unavailable");
    if (viewer && viewer !== user.steamid) return failure("identity-mismatch");
    viewer = user.steamid;
    return null;
  }
  for (const nodeID of ["application_config", "webui_config"]) {
    const node = rootDocument.getElementById(nodeID);
    if (node) identityNodeSeen = true;
    const userInfoRaw = node?.getAttribute("data-userinfo");
    if (!userInfoRaw) continue;
    userInfoSeen = true;
    if (userInfoRaw.length > 64000) return failure("identity-unverified", "userinfo-too-large");
    let user;
    try { user = JSON.parse(userInfoRaw); } catch { return failure("identity-unverified", "userinfo-malformed"); }
    const issue = acceptIdentity(user);
    if (issue) return issue;
  }
  if (globalUserConfig !== undefined) {
    if (!globalUserConfig || typeof globalUserConfig !== "object" || Array.isArray(globalUserConfig))
      return failure("identity-unverified", "userinfo-malformed");
    // Valve's current config bootstrap also consumes window.UserConfig.
    // Read only these two identity fields; never copy or serialize the object.
    const issue = acceptIdentity({logged_in:globalUserConfig.logged_in, steamid:globalUserConfig.steamid});
    if (issue) return issue;
  }
  if (!validAccount(viewer)) return failure("identity-unverified",
    !identityNodeSeen ? "identity-node-unavailable" : !userInfoSeen ? "userinfo-attribute-unavailable" : "viewer-id-unavailable");
  if (!discovering && viewer !== expectedAccountId) return failure("account-mismatch");
  const raw = rootDocument.getElementById("gameslist_config")?.getAttribute("data-profile-gameslist");
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
  }
  const initial = readDocument(document, window.g_steamID, window.UserConfig);
  if (initial.reason !== "identity-node-unavailable") return initial;
  // The live page may have consumed its bootstrap nodes. Re-read only Valve's
  // own authenticated all-games document; WebKit supplies its existing cookies.
  // An inert document is validated by exactly the same identity/ownership rules.
  // A profile URL or a successful HTTP response alone never proves ownership.
  return (async () => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 12000);
    let reader;
    try {
      const response = await fetch(location.href, {
        credentials: "same-origin", redirect: "follow", cache: "no-store", signal: controller.signal,
      });
      const resolved = new URL(response.url);
      if (resolved.protocol !== "https:" || resolved.hostname !== "steamcommunity.com" ||
          resolved.username || resolved.password || (resolved.port && resolved.port !== "443")) return initial;
      if (/^\/login\//.test(resolved.pathname)) return failure("signed-out", "userinfo-not-signed-in");
      if (!response.ok || !/^\/(profiles\/[0-9]{17}|id\/[^/]+)\/games\/?$/.test(resolved.pathname) ||
          resolved.searchParams.getAll("tab").length !== 1 || resolved.searchParams.get("tab") !== "all" ||
          !/^text\/html(?:;|$)/i.test(response.headers.get("content-type") || "") || !response.body) return initial;
      reader = response.body.getReader();
      let bytes = 0, html = "";
      const decoder = new TextDecoder();
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        bytes += chunk.value.byteLength;
        if (bytes > 8000000) { await reader.cancel(); return failure("too-large"); }
        html += decoder.decode(chunk.value, { stream: true });
      }
      html += decoder.decode();
      const serverDocument = new DOMParser().parseFromString(html, "text/html");
      const result = readDocument(serverDocument);
      const resolvedOwner = resolved.pathname.match(/^\/profiles\/([0-9]{17})\/games\/?$/)?.[1];
      if (result.status === "complete" && resolvedOwner && resolvedOwner !== result.accountId) return failure("identity-mismatch");
      return result;
    } catch { return initial; }
    finally { clearTimeout(timer); try { reader?.releaseLock(); } catch {} }
  })();
})();
