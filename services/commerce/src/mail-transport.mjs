/** A local MTA keeps delivery credentials out of this application on o2switch. */
export function mailTransportOptions(env) {
  const required = (name) => {
    if (!env[name]) throw Error("Missing configuration: " + name);
    return env[name];
  };
  const common = {
    disableFileAccess: true,
    disableUrlAccess: true,
    connectionTimeout: 10000,
    greetingTimeout: 10000,
    socketTimeout: 20000,
  };
  const mode = env.MAIL_TRANSPORT || "smtp";
  if (mode === "local-smtp")
    return {
      ...common,
      host: "127.0.0.1",
      port: 25,
      secure: false,
      ignoreTLS: true,
    };
  if (mode !== "smtp") throw Error("Invalid mail transport");
  const port = Number(env.SMTP_PORT || 465);
  if (![465, 587].includes(port))
    throw Error("SMTP requires TLS on port 465 or 587");
  return {
    ...common,
    host: required("SMTP_HOST"),
    port,
    secure: port === 465,
    requireTLS: true,
    tls: { minVersion: "TLSv1.2" },
    auth: { user: required("SMTP_USER"), pass: required("SMTP_PASSWORD") },
  };
}
