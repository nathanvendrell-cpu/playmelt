# Inventaire Windows statique — première brique de recherche

`pe_inspect.py` décrit les exigences déclarées par un fichier PE Windows fourni
explicitement. Il ne charge pas le programme, ne recherche pas ses DLL et
n'exécute aucun code Windows. Il ne constitue pas un moteur de compatibilité.
Python 3.9+ et sa bibliothèque standard suffisent sur macOS/POSIX.

Depuis la racine du projet :

```sh
python3 -B research/windows_native/pe_inspect.py --pretty -- '/chemin/jeu.exe' '/chemin/module.dll'
```

Les chemins après `--` sont des exemples à remplacer par les fichiers choisis.
Aucun inventaire de dossier, accès Steam, réseau ou découverte automatique n'a
lieu. Un nom de DLL importée est une donnée : il n'est jamais ouvert, même s'il
contient un chemin. Le programme ne demande ni administrateur ni installation.

## Contrat JSON, version 1

La sortie standard contient un seul objet :

```json
{
  "schemaVersion": 1,
  "kind": "playmelt-pe-inspection",
  "executionPerformed": false,
  "wineUsed": false,
  "supportDetermined": false,
  "files": []
}
```

Chaque entrée `files` porte `input` et `status: "ok" | "error"`.
Une entrée valide contient :

- `size`, `sha256`, `format`, `architecture` et l'en-tête `coff` ;
- `entryPoint` : RVA, VA préférée, offset fichier et section exécutable déclarée ;
- `subsystem`, `declaredVersions` et `imageFeatures` : déclarations Windows,
  présence des exceptions, relocalisations, CLR et certificat, sans validation
  du système minimum, de la signature ou des mesures de protection ;
- `imports` et `delayImports` : DLL, noms/hints ou ordinaux, provenance de la
  table et mode d'adresse. Une IAT liée sans table de noms conservée produit
  `symbols: null`, `symbolStatus: "unavailable-bound-iat"` et un avertissement ;
- `tls` : gabarit statique, stockage de l'index, zéro initial et adresses des
  callbacks. Ces callbacks ne sont jamais appelés ;
- `graphicsHints`, `inventory`, `warnings`, `limitations` et les trois marqueurs
  de non-exécution ci-dessus.

Les indices Direct3D 12, DXGI, NVIDIA NGX et AMD FidelityFX/FSR proviennent
uniquement des noms de DLL/symboles. **NGX ne prouve aucune version de DLSS**, et
l'absence d'import FSR ne prouve pas l'absence de FSR. Le chargement dynamique,
les plugins, le code lié statiquement, les shaders et les exécutables empaquetés
ou déchiffrés à l'exécution peuvent masquer des exigences. Aucun verdict HDR,
anti-cheat, DRM, instruction CPU, compatibilité ou performance n'est émis.

Une erreur fournit `error: {code, message}`, sans traceback ni contenu brut.
Codes de sortie : `0` tous les fichiers acceptés ; `1` au moins un rejet ; `2`
erreur d'usage CLI. Une inspection acceptée signifie seulement que ce sous-ensemble
du format a pu être inventorié.

## Bornes et règles de lecture

Fichiers réguliers `.exe`/`.dll` uniquement, 64 octets à 256 Mio, au plus 32
fichiers explicites par appel, traités séquentiellement. Symlinks de fichier,
FIFO et périphériques refusés. L'ouverture est en lecture seule et non bloquante.
`pread` lit uniquement les plages nécessaires ; SHA-256 est calculé en blocs de
1 Mio. Aucun fichier entier de 256 Mio n'est copié en mémoire. Identité, taille
et dates sont contrôlées avant/après : cela détecte les changements ordinaires,
sans constituer une garantie contre un auteur concurrent privilégié.

Bornes par fichier : 96 sections, 16 répertoires, 1 024 DLL cumulées,
4 096 symboles/DLL, 32 768 symboles cumulés, 1 024 callbacks TLS, 4 096 octets par
chaîne, 1 Mio de noms cumulés et 64 Mio de lectures de métadonnées. Budget de
sortie compacte : 16 Mio par lot ; `--pretty` ajoute seulement l'indentation.
Des seuils atteints produisent une erreur, jamais une liste tronquée présentée
comme complète.

Les calculs vérifient les plages du fichier et de l'image. Les sections qui se
chevauchent, adresses non adossées à des octets, bits réservés, chaînes/tableaux
sans terminaison et structures ambiguës sont rejetés. Le répertoire certificat
utilise un offset de fichier ; les autres utilisent des RVA. Les adresses TLS
sont des VA. Le delay-load moderne est en RVA ; la forme historique PE32 utilise
des pointeurs VA, convertis relativement à l'image préférée. Les parcours sont
linéaires et bornés : aucune récursion dans les dépendances ou pointeurs.

Ce parseur strict ne reproduit pas les tolérances du chargeur Windows. Les objets
COFF sans image PE, archives, extensions futures et dispositions traversant
plusieurs sections pour une même structure ne sont pas pris en charge.

## Vérification reproductible

```sh
nice -n 15 python3 -B -m unittest discover -s research/windows_native -p 'test_pe_inspect.py' -v
```

La suite comprend 62 tests : PE32/PE32+, RVA/VA, imports/ordinaux/delay-load,
TLS, IAT liée, limites, corruption/troncature, chevauchements, symlink/FIFO,
fichier modifié, fermeture des descripteurs, contrat CLI et 128 mutations
synthétiques déterministes. Les fixtures font environ 10 Kio, sont créées dans
un `TemporaryDirectory` et supprimées même si le test échoue. Aucun véritable
EXE de jeu, Wine, Steam, GPU ou sous-processus Windows n'est utilisé.

## Source et portée

Référence primaire : [Microsoft — PE Format](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format),
notamment les en-têtes COFF/optionnels, `.idata`, delay-load et `.tls` (consultée
le 25 octobre 2026). Le code est une implémentation d'inspection indépendante.

La prochaine décision se fonde sur les dépendances effectivement observées dans
des fichiers que l'utilisateur aura choisis. Il restera à implémenter et prouver
séparément le chargement PE, les API système, le CPU, le graphisme et les services
du jeu. Cette brique n'active aucune route de lancement dans Playmelt.
