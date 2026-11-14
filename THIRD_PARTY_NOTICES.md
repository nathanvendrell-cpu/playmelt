# Composants tiers de Playmelt

Playmelt est propriétaire (voir `LICENSE`). Les composants ci-dessous ne sont pas
la propriété de 7AGENCY : ils restent sous leur propre licence, que la licence
Playmelt ne restreint pas.

| Composant | Utilisation dans Playmelt | Licence | Distribution |
|---|---|---|---|
| Sparkle 2.10.1 | Mises à jour de l'app | MIT | Intégré à l'app (`Contents/Frameworks`) |
| CPython 3.13.18 et composants de python-build-standalone 20261110 | Interpréteur portable des assistants Python | Python-2.0 / CNRI-Python et licences amont des composants liés, dont OpenSSL Apache-2.0 | Intégrés à `Contents/Resources/Python` ; versions, empreintes et textes complets dans `Python/share/playmelt-runtime` |
| Legendary 0.21.1 et dépendances Python | Adaptateur Epic dans un processus Python séparé | Legendary GPL-3.0-or-later ; licences propres aux dépendances | Wheels amont non modifiées, notices et archives sources correspondantes dans `Python/share/playmelt-runtime` ; aucune restriction de la licence Playmelt sur ces composants |
| MinGW-w64 et bibliothèques d’exécution GCC / libstdc++ | Compilation et exécution des assistants Windows propres à Playmelt | ZPL-2.1 et notices des composants MinGW ; GPL-3.0 avec GCC Runtime Library Exception 3.1 pour les bibliothèques couvertes | Portions liées statiquement aux assistants ; textes dans `Contents/Resources/ThirdPartyLicenses` |
| Wine (build Sikarugir 10.0_6) | Exécution des jeux Windows | LGPL-2.1-or-later | Téléchargé par Playmelt depuis la source publique, empreinte SHA-256 vérifiée ; process séparé, non lié à Playmelt |
| Bibliothèques Wine (Sikarugir Wrapper 1.0.11) | Dépendances de Wine | Mixte : LGPL (GStreamer, gnutls), Apache-2.0 (MoltenVK) | Idem |
| DXMT (branche Highball 331c552) | Traduction DirectX 11 → Metal | MIT / LGPL selon les notices amont | Idem |
| D3DMetal et shims NVIDIA du Game Porting Toolkit (Apple) | Traduction DirectX 12 → Metal, DLSS → MetalFX | Licence Apple, acceptée par l'utilisateur | **Jamais distribués par Playmelt** : importés localement par l'utilisateur depuis son propre téléchargement Apple |
| Bibliothèques NVIDIA des jeux (`nvngx_*.dll`) | Chargées par le jeu | Licence NVIDIA | **Jamais copiées ni redistribuées** |

Obligations LGPL : les sources de Wine et de ses bibliothèques sont disponibles
auprès des projets amont cités. Playmelt les lance comme des programmes séparés
et ne restreint ni leur modification ni leur rétro-ingénierie.

Les noms Steam, Epic Games, GOG, Xbox, NVIDIA, DLSS, Apple, Metal et MetalFX
appartiennent à leurs détenteurs respectifs. Playmelt n'est affilié à aucun d'eux.
