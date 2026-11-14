import { randomBytes, scrypt, timingSafeEqual } from "node:crypto";
import { promisify } from "node:util";

const derive = promisify(scrypt);
const options = Object.freeze({ N: 131072, r: 8, p: 1, maxmem: 192 * 1024 * 1024 });
const format = /^scrypt\$131072\$8\$1\$([A-Za-z0-9_-]{22})\$([A-Za-z0-9_-]{86})$/;
const dummy = "scrypt$131072$8$1$" + Buffer.alloc(16).toString("base64url") + "$" + Buffer.alloc(64).toString("base64url");
let active = 0;

export function validNewPassword(value) {
  return typeof value === "string" && [...value].length >= 15 && [...value].length <= 128 && Buffer.byteLength(value) <= 1024;
}
export function validLoginPassword(value) {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= 1024;
}
async function key(password, salt) {
  if (active >= 2) throw Object.assign(Error("Authentication busy"), { code: "AUTH_BUSY" });
  active++;
  try { return await derive(password, salt, 64, options); }
  finally { active--; }
}
export async function hashPassword(value) {
  if (!validNewPassword(value)) throw Error("Invalid new password");
  const salt = randomBytes(16), hash = await key(value, salt);
  return `scrypt$131072$8$1$${salt.toString("base64url")}$${hash.toString("base64url")}`;
}
export async function verifyPassword(value, stored) {
  if (!validLoginPassword(value)) return false;
  const match = format.exec(stored || ""), fields = match || format.exec(dummy);
  const actual = await key(value, Buffer.from(fields[1], "base64url"));
  return timingSafeEqual(actual, Buffer.from(fields[2], "base64url")) && !!match;
}
