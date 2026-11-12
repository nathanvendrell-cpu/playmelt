import { existsSync, lstatSync, mkdirSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, relative, sep } from "node:path";

const inside = (parent, path) => {
  const r = relative(parent, path);
  return r !== "" && !r.startsWith(".." + sep) && r !== ".." && !isAbsolute(r);
};
function checkPrivate(path, directory = false) {
  const stat = lstatSync(path);
  if (
    stat.isSymbolicLink() ||
    !(directory ? stat.isDirectory() : stat.isFile()) ||
    (stat.mode & 0o077) !== 0 ||
    (process.getuid && stat.uid !== process.getuid())
  )
    throw Error("Private storage ownership or permissions invalid");
}
export function validatePrivateStorage({
  root,
  documentRoot,
  database,
  signingKey,
}) {
  if (![root, documentRoot, database, signingKey].every(isAbsolute))
    throw Error("Absolute private storage paths required");
  const web = realpathSync(documentRoot);
  mkdirSync(root, { recursive: true, mode: 0o700 });
  checkPrivate(root, true);
  const privateRoot = realpathSync(root);
  if (
    privateRoot === web ||
    inside(web, privateRoot) ||
    inside(privateRoot, web)
  )
    throw Error("Private storage overlaps public document root");
  for (const file of [database, signingKey]) {
    if (!inside(root, file))
      throw Error("File must stay inside private storage");
    mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
    checkPrivate(dirname(file), true);
    if (
      !inside(privateRoot, realpathSync(dirname(file))) &&
      realpathSync(dirname(file)) !== privateRoot
    )
      throw Error("Private path escapes through a symlink");
    if (existsSync(file)) checkPrivate(file);
  }
  checkPrivate(signingKey);
}
