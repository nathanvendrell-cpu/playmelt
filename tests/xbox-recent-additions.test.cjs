'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '../index.html'), 'utf8');

test('rowSections renders official "Ajouts récents" for Xbox view with quota meta', () => {
  // Extract rowSections from index.html
  const start = html.indexOf('function rowSections() {');
  const end = html.indexOf('function renderRows() {', start);
  assert(start > 0 && end > start);
  const rowSectionsCode = html.slice(start, end);

  const mockGames = [
    { id: 'xbox:1', title: 'Grabbed by the Ghoulies', store: 'xbox', gamePassRecent: 0, lastPlayed: 0 },
    { id: 'xbox:2', title: "John Carpenter's Toxic Commando", store: 'xbox', gamePassRecent: 1, lastPlayed: 0 },
    { id: 'xbox:3', title: 'HOPE IN THE CITY', store: 'xbox', gamePassRecent: 2, lastPlayed: 0 },
    { id: 'xbox:4', title: 'Thronefall', store: 'xbox', gamePassRecent: 3, lastPlayed: 0 },
    { id: 'xbox:5', title: 'Old Random Game', store: 'xbox', gamePassRecent: -1, lastPlayed: 0 }
  ];

  const context = {
    ui: { view: 'xbox', listMode: 'grid' },
    state: { games: mockGames, xbox: { remainingCloudHours: 14 } },
    filteredGames: (sorted) => mockGames.filter(g => g.store === 'xbox'),
  };

  vm.createContext(context);
  vm.runInContext(rowSectionsCode, context);
  const sections = context.rowSections();

  const recentSection = sections.find(s => s.title === 'Ajouts récents');
  assert(recentSection, 'Section "Ajouts récents" should exist in Xbox view');
  assert.equal(recentSection.meta, '14 h restantes ce mois');
  assert.equal(recentSection.games.length, 4);
  assert.equal(recentSection.games[0].title, 'Grabbed by the Ghoulies');
  assert.equal(recentSection.games[1].title, "John Carpenter's Toxic Commando");
  assert.equal(recentSection.games[2].title, 'HOPE IN THE CITY');
  assert.equal(recentSection.games[3].title, 'Thronefall');
});
