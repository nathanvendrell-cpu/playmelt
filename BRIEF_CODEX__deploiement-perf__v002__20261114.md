# Brief Codex — déployer les correctifs perf, v002 (Claude M3, 14/11/2026, 00 h 50)

Réponds en français. Remplace la v001 (conservée). Demandes de Nathan : « vois avec codex pour déployer tes
correction » puis « go le plein écran et profiter du mode game ». Tu édites ce dépôt : intègre ces changements à
ton prochain build/installation, sans rien écraser. Rien n'est commité ni installé par Claude.

## Changements (tous non commités)

1. `Core.swift`
   - `localGameEnvironmentExports` : FF7 Rebirth → `WINEESYNC="1"` après `WINEMSYNC="0"`.
   - `ensureLaunchScript` : exécutable toujours en chemin absolu ; `exec "\(wineLauncher)"` ;
     conditions de régénération (chemin absolu, esync Rebirth, Wine du bundle, anciens `-windowed` / `-screen-fullscreen 0`).
   - Nouvel `enum GameModeRuntime` : crée `Runtime/playmelt-wine10-dxmt-20261017/PlaymeltGame.app`
     (copies APFS de `wine` et `wineserver`, liens relatifs `lib` et `share`, Info.plist catégorie jeu +
     `LSSupportsGameMode`). Aucun fichier du moteur modifié. Repli sur `engine/bin/wine` si la création échoue.
   - Plein écran sans bordure : Unreal `-fullscreen -ResX -ResY` (au lieu de `-windowed … -WinX -WinY`),
     Unity `-screen-fullscreen 1 -window-mode borderless`.
2. `main.swift` (une ligne, `launchManagedEpic`) : `scriptExecutable:target.appendingPathComponent(chosen).path`.
   **Indispensable** : sans elle, le chemin absolu fait échouer `launchWithScript` pour les jeux Epic Windows.
3. `EpicConnector.swift` : le validateur et la réécriture acceptent aussi
   `…/PlaymeltGame.app/Contents/MacOS/wine`.
4. `GameDisplayMetadata.swift` et `scripts/game_display_quality.py` : fenêtre = bureau entier de l'écran visé,
   origine de l'écran (plus de marge 32/80 ni de décalage 16/40). La politique `external-windowed-v1` garde son nom
   (identifiant vérifié à six endroits) ; la protection interdit toujours capture d'écran et changement de mode.
5. Tests ajustés : `tests/GameDisplayPolicyTests.swift` (1920×1080), `tests/game_display_quality_test.py`.

## Preuves (14/11/2026, M3 Max, macOS 27.0.1)

- Journal `gamepolicyd` : Wine nu (même avec plist embarqué modifié) jamais reconnu ; le même binaire lancé depuis
  le bundle → « Found game … labelReason=LSSupportsGameMode (Info.plist) », « Full screen gaming session is now
  active », puis « Game mode enabled » quand la fenêtre est au premier plan. Fenêtre de test Win32 plein écran,
  préfixe jetable, aucun jeu.
- Bundle créé par le code réel de `GameModeRuntime.ensure` : reconnu comme jeu, idempotent, repli `false` sans moteur.
- Compilation hors dépôt (-Onone, 00 h 45) + `--self-test` : 245 passed, 0 failed.
- `EpicOperationTests` : 49 PASS avec le Wine du moteur et 49 PASS avec le Wine du bundle.
- `GameDisplayPolicyTests` : passé ; `game_display_quality_test.py` : 11 OK ; `session_benchmark_test.py`,
  `display_routing_test.py` : OK.
- Banc de synchronisation : serveur 495–550 ms · esync 234–267 ms · msync 75 ms (20 000 échanges, synthétique).

## Non vérifié — à tester avec Nathan après installation

- Aucun vrai jeu lancé : `-fullscreen` (Unreal) et `-window-mode borderless` (Unity) sous Wine, Rebirth sous esync,
  comportement avec deux écrans. Retour arrière : les lignes correspondantes de `Core.swift`.
- Spider-Man 2 (lanceur Python propre) : ni mesure FPS, ni plein écran, ni mode Jeu.
- Contrôle du mode Jeu en jeu :
  `/usr/bin/log show --last 5m --predicate 'process == "gamepolicyd" AND subsystem == "com.apple.gamepolicyd"' | grep -E 'Found game|Game mode'`

## À faire

- Garder ces changements dans ton build ; sauvegarder l'app installée avant remplacement ; rejouer auto-tests et tests UI.
- Voir aussi `BRIEF_CODEX__limite-fps-upscaling__v001__20261114.md`.
