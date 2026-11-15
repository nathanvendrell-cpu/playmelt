const test = require("node:test");
const assert = require("node:assert/strict");

const GEFORCE_TIERS = {
  performance: {
    id: "performance",
    name: "Performance",
    quota: 100,
    sessionLimitHours: 6,
    maxRolloverHours: 15,
    spec: "Jusqu’à 1440p · RTX ON"
  },
  ultimate: {
    id: "ultimate",
    name: "Ultimate",
    quota: 100,
    sessionLimitHours: 8,
    maxRolloverHours: 15,
    spec: "Jusqu’à 4K 120/240 FPS · RTX 4080/5080"
  },
  founders: {
    id: "founders",
    name: "Fondateur",
    quota: -1, // Illimité
    sessionLimitHours: 6,
    maxRolloverHours: 0,
    spec: "Avantage pionnier à vie"
  },
  free: {
    id: "free",
    name: "Gratuit",
    quota: 0,
    sessionLimitHours: 1,
    maxRolloverHours: 0,
    spec: "Accès standard · File d’attente"
  }
};

function calculateGeForceStats(usage, currentTierId) {
  const tier = GEFORCE_TIERS[currentTierId] || GEFORCE_TIERS.performance;
  const usedSeconds = usage.usedSeconds || 0;
  const usedHours = usedSeconds / 3600;

  if (tier.quota > 0) {
    const quotaSeconds = (tier.quota + Math.min(usage.rolloverHours || 0, tier.maxRolloverHours)) * 3600;
    const remainingSeconds = Math.max(0, quotaSeconds - usedSeconds);
    const remainingHours = Math.max(0, Math.ceil(remainingSeconds / 3600));
    const isLow = remainingHours <= 15;
    return {
      tier: tier.id,
      name: tier.name,
      sessionLimit: `${tier.sessionLimitHours} h max / session`,
      isUnlimited: false,
      isPerSession: false,
      quotaHours: tier.quota,
      usedHours: Math.round(usedHours * 10) / 10,
      remainingHours,
      isLow,
      label: `${remainingHours} h restantes`
    };
  } else if (tier.quota < 0) {
    return {
      tier: tier.id,
      name: tier.name,
      sessionLimit: `${tier.sessionLimitHours} h max / session`,
      isUnlimited: true,
      isPerSession: false,
      quotaHours: -1,
      usedHours: Math.round(usedHours * 10) / 10,
      remainingHours: -1,
      isLow: false,
      label: "Illimité"
    };
  } else {
    return {
      tier: tier.id,
      name: tier.name,
      sessionLimit: `${tier.sessionLimitHours} h max / session`,
      isUnlimited: false,
      isPerSession: true,
      quotaHours: 0,
      usedHours: Math.round(usedHours * 10) / 10,
      remainingHours: 0,
      isLow: false,
      label: "1 h / session"
    };
  }
}

test("GeForce NOW: Performance tier defaults to 100h quota and 6h session limit", () => {
  const stats = calculateGeForceStats({ usedSeconds: 0 }, "performance");
  assert.equal(stats.quotaHours, 100);
  assert.equal(stats.remainingHours, 100);
  assert.equal(stats.sessionLimit, "6 h max / session");
  assert.equal(stats.isUnlimited, false);
  assert.equal(stats.label, "100 h restantes");
  assert.equal(stats.isLow, false);
});

test("GeForce NOW: Performance tier tracks played time and warns on low quota", () => {
  // Played 88 hours out of 100 -> 12 hours remaining
  const stats = calculateGeForceStats({ usedSeconds: 88 * 3600 }, "performance");
  assert.equal(stats.remainingHours, 12);
  assert.equal(stats.usedHours, 88);
  assert.equal(stats.isLow, true);
  assert.equal(stats.label, "12 h restantes");
});

test("GeForce NOW: Ultimate tier has 100h quota and 8h session limit", () => {
  const stats = calculateGeForceStats({ usedSeconds: 10 * 3600 }, "ultimate");
  assert.equal(stats.quotaHours, 100);
  assert.equal(stats.remainingHours, 90);
  assert.equal(stats.sessionLimit, "8 h max / session");
  assert.equal(stats.isUnlimited, false);
  assert.equal(stats.label, "90 h restantes");
});

test("GeForce NOW: Founders tier has unlimited quota and 6h session limit", () => {
  const stats = calculateGeForceStats({ usedSeconds: 150 * 3600 }, "founders");
  assert.equal(stats.isUnlimited, true);
  assert.equal(stats.remainingHours, -1);
  assert.equal(stats.sessionLimit, "6 h max / session");
  assert.equal(stats.label, "Illimité");
  assert.equal(stats.isLow, false);
});

test("GeForce NOW: Free tier is per-session (1h max)", () => {
  const stats = calculateGeForceStats({ usedSeconds: 2 * 3600 }, "free");
  assert.equal(stats.isPerSession, true);
  assert.equal(stats.sessionLimit, "1 h max / session");
  assert.equal(stats.label, "1 h / session");
});

test("GeForce NOW: Rollover capped at 15 hours", () => {
  // Rollover of 20 hours capped at 15 -> total 115 hours quota
  const stats = calculateGeForceStats({ usedSeconds: 15 * 3600, rolloverHours: 20 }, "performance");
  assert.equal(stats.remainingHours, 100); // 115 - 15 = 100
});
