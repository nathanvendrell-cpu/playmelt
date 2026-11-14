import { constants, openSync, fstatSync, closeSync, readFileSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, relative, sep } from "node:path";

export function loadGoogleOAuth(path, { privateRoot, publicURL }) {
  if (!path) return {};
  if (!isAbsolute(path)) throw Error("Private Google configuration required");
  const root = realpathSync(privateRoot), parent = realpathSync(dirname(path));
  const part = relative(root, parent);
  if (part === ".." || part.startsWith(".." + sep) || isAbsolute(part))
    throw Error("Private Google configuration required");
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.nlink !== 1 || stat.size > 16384 || stat.mode & 0o077 ||
        (process.getuid && stat.uid !== process.getuid())) throw Error("Private Google configuration required");
    const web = JSON.parse(readFileSync(fd, "utf8")).web;
    const callback = publicURL.replace(/\/$/, "") + "/v1/auth/google/callback";
    if (!web || !/^[A-Za-z0-9_-]{6,200}\.apps\.googleusercontent\.com$/.test(web.client_id || "") ||
        !/^[A-Za-z0-9_-]{16,256}$/.test(web.client_secret || "") ||
        !Array.isArray(web.redirect_uris) || !web.redirect_uris.includes(callback))
      throw Error("Invalid Google OAuth configuration");
    // Provider endpoints and scopes are fixed in the OAuth module, never taken from this file.
    return { googleClientID: web.client_id, googleClientSecret: web.client_secret };
  } finally { closeSync(fd); }
}
