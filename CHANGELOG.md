# Changelog

Toutes les évolutions notables du kit. Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/),
versionnage sémantique. La question à laquelle ce fichier répond : « qu'est-ce qui change si je mets à jour ? »

À partir de la version suivant [1.9.1], les entrées sous ce paragraphe sont générées par
[release-please](https://github.com/googleapis/release-please) à partir des Conventional Commits :
elles adoptent son format (sections *Features* / *Bug Fixes*, lien de comparaison, sha par entrée)
plutôt que la rédaction manuelle ci-dessous. Les entrées antérieures sont conservées telles quelles.

## [2.0.0](https://github.com/phmatray/ai-migration-kit/compare/v1.16.0...v2.0.0) (2026-08-31)


### ⚠ BREAKING CHANGES

* **skills:** four skills are renamed with no aliases, shims or deprecation window — the old invocations stop resolving. `get-repo-profile` → `profile-repo`; `followups` → `review-followups`; `systematic-debugging` → `debug-issue`; `legacy-upgrade` → `migrate-legacy`. The `/migrate*`, `/migrate-followups` and every other `commands/` entry point is unchanged, as are the scripts inside the renamed folders (`repo-profile.sh`, `find-polluter.sh`, `hitl-loop.template.sh`, `scripts/followups.py`) and the `tests/followups/` and `tests/repo-profile/` suites.
* **auto-dev:** dispatch workers as background sub-agents, never claude -p ([#314](https://github.com/phmatray/ai-migration-kit/issues/314)) (#328)

### Features

* **adr:** ship AdrMcp as a recommended server and record the kit's ADRs ([#316](https://github.com/phmatray/ai-migration-kit/issues/316)) ([#340](https://github.com/phmatray/ai-migration-kit/issues/340)) ([248fd9f](https://github.com/phmatray/ai-migration-kit/commit/248fd9f783cfd13d8ef1356e341ced470442ad53))
* **auto-dev:** bound orchestrator and worker context with counted budgets ([#270](https://github.com/phmatray/ai-migration-kit/issues/270)) ([#381](https://github.com/phmatray/ai-migration-kit/issues/381)) ([3408f99](https://github.com/phmatray/ai-migration-kit/commit/3408f99e27107e6209b89ea6f353b30830e268a7))
* **auto-dev:** dispatch workers as background sub-agents, never claude -p ([#314](https://github.com/phmatray/ai-migration-kit/issues/314)) ([#328](https://github.com/phmatray/ai-migration-kit/issues/328)) ([f630a2a](https://github.com/phmatray/ai-migration-kit/commit/f630a2a98d451c59e4634d45275bd727d44b5756))
* **auto-dev:** mandatory lessons block in Step 6, backed by a decision tally ([#318](https://github.com/phmatray/ai-migration-kit/issues/318)) ([#368](https://github.com/phmatray/ai-migration-kit/issues/368)) ([94b8f1b](https://github.com/phmatray/ai-migration-kit/commit/94b8f1b93932190581e47ebd63785ce4b71acdad))
* **auto-dev:** survey dispatches only the frontier — blocked, parent and assigned issues hold ([#317](https://github.com/phmatray/ai-migration-kit/issues/317)) ([#360](https://github.com/phmatray/ai-migration-kit/issues/360)) ([caf132b](https://github.com/phmatray/ai-migration-kit/commit/caf132b4ff4c9f2bdcfb42dcc1f52fabde55cc32))
* **create-issue:** --seed #N and --grill inputs ([#312](https://github.com/phmatray/ai-migration-kit/issues/312)) ([#334](https://github.com/phmatray/ai-migration-kit/issues/334)) ([e740bc5](https://github.com/phmatray/ai-migration-kit/commit/e740bc539780d816a8a2a8f1b1fbf7bfe811f2cc))
* **create-issue:** decompose large work into tracer-bullet children with blocking edges ([#315](https://github.com/phmatray/ai-migration-kit/issues/315)) ([#344](https://github.com/phmatray/ai-migration-kit/issues/344)) ([2bf19ce](https://github.com/phmatray/ai-migration-kit/commit/2bf19ce01c404191dcafdfdd18a80f0f5fe10ba8))
* **create-issue:** give the Spec a contract for acceptance criteria, seams, and out of scope ([#310](https://github.com/phmatray/ai-migration-kit/issues/310)) ([#327](https://github.com/phmatray/ai-migration-kit/issues/327)) ([421380e](https://github.com/phmatray/ai-migration-kit/commit/421380e33c5add35ae655c1214695133ad5a975c))
* **create-issue:** prior rejections live as rejected ADRs searched through AdrMcp ([#319](https://github.com/phmatray/ai-migration-kit/issues/319)) ([#366](https://github.com/phmatray/ai-migration-kit/issues/366)) ([25a37bb](https://github.com/phmatray/ai-migration-kit/commit/25a37bbde5d6786f0165a55a389dab8c419429cd))
* **decisions:** widen R10 to hooks/ and skill-root scripts ([#307](https://github.com/phmatray/ai-migration-kit/issues/307)) ([#380](https://github.com/phmatray/ai-migration-kit/issues/380)) ([9d0dda8](https://github.com/phmatray/ai-migration-kit/commit/9d0dda8515c4b3b5924ed54d8d99cebc80077209))
* **docs:** add CONTEXT.md, the kit's shared language ([#313](https://github.com/phmatray/ai-migration-kit/issues/313)) ([#336](https://github.com/phmatray/ai-migration-kit/issues/336)) ([4f3c564](https://github.com/phmatray/ai-migration-kit/commit/4f3c564b3b076ccaeafd90a8d3980bde1c2e2549))
* **docs:** document setup-repo in the architecture diagrams ([#279](https://github.com/phmatray/ai-migration-kit/issues/279)) ([#356](https://github.com/phmatray/ai-migration-kit/issues/356)) ([564f74e](https://github.com/phmatray/ai-migration-kit/commit/564f74ed671b585628a952940a0540a9769b0c4d))
* **evals:** trigger contracts live in evals/*.json ([#331](https://github.com/phmatray/ai-migration-kit/issues/331)) ([#338](https://github.com/phmatray/ai-migration-kit/issues/338)) ([dce7d5b](https://github.com/phmatray/ai-migration-kit/commit/dce7d5bb88f5c89ea2df9c49372b875d5ba02332))
* **followups:** render owner decisions as a questionnaire and ingest answers ([#332](https://github.com/phmatray/ai-migration-kit/issues/332)) ([#371](https://github.com/phmatray/ai-migration-kit/issues/371)) ([c51dfc7](https://github.com/phmatray/ai-migration-kit/commit/c51dfc77a69e18a551b89c07a4949a9ce129777e))
* **get-repo-profile:** detect tracker, domain language, ADR, out-of-scope and standards facts ([#311](https://github.com/phmatray/ai-migration-kit/issues/311)) ([#329](https://github.com/phmatray/ai-migration-kit/issues/329)) ([02e0290](https://github.com/phmatray/ai-migration-kit/commit/02e0290bf2b97f29f55eae91abf79289a2f5e422))
* **hooks:** git write-gate denies destructive and unguarded git writes ([#326](https://github.com/phmatray/ai-migration-kit/issues/326)) ([#353](https://github.com/phmatray/ai-migration-kit/issues/353)) ([ee749cc](https://github.com/phmatray/ai-migration-kit/commit/ee749cc25701c03ca8602753fb70ce27e1b56a7a))
* **implement-issue:** review the diff against the Spec, check plan freshness, share one exploration pass ([#322](https://github.com/phmatray/ai-migration-kit/issues/322)) ([#339](https://github.com/phmatray/ai-migration-kit/issues/339)) ([f07ba68](https://github.com/phmatray/ai-migration-kit/commit/f07ba6867dfd688cd07e2c04567d9e1ff4dede4b))
* **merge-pr:** append a Decisions so far line to the tracking parent when a child merges ([#365](https://github.com/phmatray/ai-migration-kit/issues/365)) ([#376](https://github.com/phmatray/ai-migration-kit/issues/376)) ([e1dfa2f](https://github.com/phmatray/ai-migration-kit/commit/e1dfa2faffa99a95a842ea0937d198e52fc63526))
* **merge-pr:** read the base CI run each merge triggers ([#355](https://github.com/phmatray/ai-migration-kit/issues/355)) ([#361](https://github.com/phmatray/ai-migration-kit/issues/361)) ([c414599](https://github.com/phmatray/ai-migration-kit/commit/c414599e7c566ca35843403dc02eee506adcee19))
* **migrate:** record a dependency-health block at phase 6's exit gate ([#267](https://github.com/phmatray/ai-migration-kit/issues/267)) ([#362](https://github.com/phmatray/ai-migration-kit/issues/362)) ([c5af559](https://github.com/phmatray/ai-migration-kit/commit/c5af5593b95e2df878eba708ce2e043c19e7b982))
* **skills:** give every skill one shared closing recap and a checked hand-off table ([#175](https://github.com/phmatray/ai-migration-kit/issues/175)) ([#383](https://github.com/phmatray/ai-migration-kit/issues/383)) ([455f701](https://github.com/phmatray/ai-migration-kit/commit/455f70132156f26017208849b2c1861c4d4a3648))
* **skills:** harmonise skill names on two rules (verb-object, family-role) ([#389](https://github.com/phmatray/ai-migration-kit/issues/389)) ([d1e53de](https://github.com/phmatray/ai-migration-kit/commit/d1e53de07138c4a24f5bf9ae777e736b5a626a0a))
* **skills:** lifecycle skills stop depending on the third-party superpowers plugin ([#324](https://github.com/phmatray/ai-migration-kit/issues/324)) ([#374](https://github.com/phmatray/ai-migration-kit/issues/374)) ([d718e76](https://github.com/phmatray/ai-migration-kit/commit/d718e763449ae0181b71c89a2843289ed92fb470))
* **skills:** skill descriptions on a token budget, with a CI soft ceiling ([#323](https://github.com/phmatray/ai-migration-kit/issues/323)) ([#359](https://github.com/phmatray/ai-migration-kit/issues/359)) ([9917366](https://github.com/phmatray/ai-migration-kit/commit/99173663bb09dd015f9ca3f7ec93410e8026e674))
* **skills:** sync-with-main sources the other side's intent before resolving a semantic conflict ([#321](https://github.com/phmatray/ai-migration-kit/issues/321)) ([#341](https://github.com/phmatray/ai-migration-kit/issues/341)) ([53b7317](https://github.com/phmatray/ai-migration-kit/commit/53b73178143f9863c8a0028f2185a9fdd95c8f48))
* **systematic-debugging:** build a tight feedback loop before hypothesising ([#320](https://github.com/phmatray/ai-migration-kit/issues/320)) ([#330](https://github.com/phmatray/ai-migration-kit/issues/330)) ([b01cdc5](https://github.com/phmatray/ai-migration-kit/commit/b01cdc5f624f2a3bdcb4355cafd7befcc027e260))


### Bug Fixes

* **auto-dev:** count workflow-nested sub-agent transcripts too ([#309](https://github.com/phmatray/ai-migration-kit/issues/309)) ([#382](https://github.com/phmatray/ai-migration-kit/issues/382)) ([eccd43e](https://github.com/phmatray/ai-migration-kit/commit/eccd43ea462a2c17de4c3f6df6b58d8cd4463bf9))
* **ci:** stop the release-title gate forcing a release for nested eval fixtures ([#58](https://github.com/phmatray/ai-migration-kit/issues/58)) ([#364](https://github.com/phmatray/ai-migration-kit/issues/364)) ([41ab586](https://github.com/phmatray/ai-migration-kit/commit/41ab5860d8df047e1c94148fd4c6ad58844cdacb))
* **decisions:** strip_comments handles the '\''-escaped-apostrophe idiom ([#306](https://github.com/phmatray/ai-migration-kit/issues/306)) ([#345](https://github.com/phmatray/ai-migration-kit/issues/345)) ([004cf8b](https://github.com/phmatray/ai-migration-kit/commit/004cf8bdb9d237a12d9eff18ba008a0b5ab3a6b0))
* **docs:** CLAUDE.md points at the live trigger-contract home; README cross-references corrected ([#351](https://github.com/phmatray/ai-migration-kit/issues/351)) ([d1e19e6](https://github.com/phmatray/ai-migration-kit/commit/d1e19e6fc1d2fb2f2c84da85efbb010eddce8872))
* **implement-issue:** close the remaining raw-text comparisons in tick-plan.sh ([#215](https://github.com/phmatray/ai-migration-kit/issues/215)) ([#377](https://github.com/phmatray/ai-migration-kit/issues/377)) ([f469609](https://github.com/phmatray/ai-migration-kit/commit/f46960943ad1239ef6ffe8ada75f4815c9707126))
* **scripts:** pin LF and drop the POSIX-checkout assumptions the gates read through ([#174](https://github.com/phmatray/ai-migration-kit/issues/174)) ([#358](https://github.com/phmatray/ai-migration-kit/issues/358)) ([0463b50](https://github.com/phmatray/ai-migration-kit/commit/0463b50a2298f4ef2e0d2db4495617672676eee9))
* **scripts:** tell a re-measured HISTORICAL line apart from a genuinely stale one ([#292](https://github.com/phmatray/ai-migration-kit/issues/292)) ([#369](https://github.com/phmatray/ai-migration-kit/issues/369)) ([d51e1fc](https://github.com/phmatray/ai-migration-kit/commit/d51e1fcd5cc597b34da8aee3e2f79af3f90f8754))
* **setup-repo:** a failed Area-dropdown projection refuses, not notes ([#240](https://github.com/phmatray/ai-migration-kit/issues/240)) ([#350](https://github.com/phmatray/ai-migration-kit/issues/350)) ([7d32d96](https://github.com/phmatray/ai-migration-kit/commit/7d32d96ad066d2cca47dbf299a9242bc716c40c1))
* **setup-repo:** every gh/OS refusal in repo-setup.sh names the cause it observed ([#222](https://github.com/phmatray/ai-migration-kit/issues/222)) ([#379](https://github.com/phmatray/ai-migration-kit/issues/379)) ([f07bbbd](https://github.com/phmatray/ai-migration-kit/commit/f07bbbdf639584d2a2232145f51464ce7546245f))
* **templates:** factor the bundle guard's refusals into a shared helper ([#302](https://github.com/phmatray/ai-migration-kit/issues/302)) ([#370](https://github.com/phmatray/ai-migration-kit/issues/370)) ([a232303](https://github.com/phmatray/ai-migration-kit/commit/a23230329ddf95f640170aad50c23f3127083c94))
* **tests:** give worktrees-ignored's scratch() its own repo per call ([#363](https://github.com/phmatray/ai-migration-kit/issues/363)) ([#375](https://github.com/phmatray/ai-migration-kit/issues/375)) ([e3229ea](https://github.com/phmatray/ai-migration-kit/commit/e3229ea8af009a55a83a9ffaefc358248e706189))

## [1.16.0](https://github.com/phmatray/ai-migration-kit/compare/v1.15.0...v1.16.0) (2026-08-30)


### Features

* **guards:** give guarded-push its own exit code for 'could not verify' ([#172](https://github.com/phmatray/ai-migration-kit/issues/172)) ([#305](https://github.com/phmatray/ai-migration-kit/issues/305)) ([00d7b97](https://github.com/phmatray/ai-migration-kit/commit/00d7b97558078c646a6e231dabb78468112b9dbb))
* **pinned-literals:** cover every restated pin, not just xunit.v3 ([#158](https://github.com/phmatray/ai-migration-kit/issues/158)) ([#283](https://github.com/phmatray/ai-migration-kit/issues/283)) ([49cce9d](https://github.com/phmatray/ai-migration-kit/commit/49cce9d4bf685bdb73fb04a69f01879381b35c31))
* **scripts:** R10 proves every executable is registered or recorded ([#252](https://github.com/phmatray/ai-migration-kit/issues/252)) ([#303](https://github.com/phmatray/ai-migration-kit/issues/303)) ([e4f6553](https://github.com/phmatray/ai-migration-kit/commit/e4f6553810694e703f10c0f8a4d2679996c68436))


### Bug Fixes

* **auto-dev:** usage_report.py counts sub-agent transcripts too ([#281](https://github.com/phmatray/ai-migration-kit/issues/281)) ([#308](https://github.com/phmatray/ai-migration-kit/issues/308)) ([09f38c8](https://github.com/phmatray/ai-migration-kit/commit/09f38c8929261b3e9f8f53d72324e008dfce3396))
* **auto-dev:** wait-ci.sh waits on every gating check, not one hardcoded name ([#188](https://github.com/phmatray/ai-migration-kit/issues/188)) ([#265](https://github.com/phmatray/ai-migration-kit/issues/265)) ([cf39c48](https://github.com/phmatray/ai-migration-kit/commit/cf39c489b07108032fe85b5417a2f3f130c31c21))
* **decisions:** R6's emit side reads what a shape builds, not what its comments say ([#274](https://github.com/phmatray/ai-migration-kit/issues/274)) ([#298](https://github.com/phmatray/ai-migration-kit/issues/298)) ([99d6124](https://github.com/phmatray/ai-migration-kit/commit/99d61243a45a2fa2fd1e3b4df5dc39d4ccd9fd9f))
* **deps:** update non-major dependencies ([#296](https://github.com/phmatray/ai-migration-kit/issues/296)) ([e1b7c8b](https://github.com/phmatray/ai-migration-kit/commit/e1b7c8baba2ad80e01b4105edd9840bf1cc8d008))
* **implement-issue:** make Step 4's worktree preparation one guarded call ([#280](https://github.com/phmatray/ai-migration-kit/issues/280)) ([#300](https://github.com/phmatray/ai-migration-kit/issues/300)) ([b6db07c](https://github.com/phmatray/ai-migration-kit/commit/b6db07c7ec9c92d1ecce5fd737b26a536f3a4267))
* **implement-issue:** the plan-locate comment scan reports a genuinely empty match, not the string "null" ([#286](https://github.com/phmatray/ai-migration-kit/issues/286)) ([#288](https://github.com/phmatray/ai-migration-kit/issues/288)) ([fec294c](https://github.com/phmatray/ai-migration-kit/commit/fec294c4bd2af6b8118c540f93908bed49c00a6c))
* **merge-pr:** route unresolved review threads to the review verdict ([#294](https://github.com/phmatray/ai-migration-kit/issues/294)) ([#295](https://github.com/phmatray/ai-migration-kit/issues/295)) ([b039739](https://github.com/phmatray/ai-migration-kit/commit/b0397391be815a8bac1e120bc19e13a609ae2aa6))
* **templates:** name BUNDLE_SRC in the guard's dist-collapses-to-root refusal ([#293](https://github.com/phmatray/ai-migration-kit/issues/293)) ([#299](https://github.com/phmatray/ai-migration-kit/issues/299)) ([672ab65](https://github.com/phmatray/ai-migration-kit/commit/672ab65152858fecb23d076c20257f65c1b48048))
* **templates:** normalise BUNDLE_SRC/BUNDLE_DIST in the guard body ([#285](https://github.com/phmatray/ai-migration-kit/issues/285)) ([#290](https://github.com/phmatray/ai-migration-kit/issues/290)) ([35255b5](https://github.com/phmatray/ai-migration-kit/commit/35255b58dfa61323c2cafc1bf042e5c287c5aeed))
* **templates:** reject a BUNDLE_DIST that escapes BUNDLE_SRC via .. in the guard step ([#301](https://github.com/phmatray/ai-migration-kit/issues/301)) ([#304](https://github.com/phmatray/ai-migration-kit/issues/304)) ([655f51a](https://github.com/phmatray/ai-migration-kit/commit/655f51af95f2d7671eb8bd9b0035c6d628bfaabb))
* **tests:** declare ENTRY_KINDS once, not twice, in the coverage-guard suite ([#287](https://github.com/phmatray/ai-migration-kit/issues/287)) ([#297](https://github.com/phmatray/ai-migration-kit/issues/297)) ([f6f8312](https://github.com/phmatray/ai-migration-kit/commit/f6f8312844441e3720b4ab471de217f8370f14da))

## [1.15.0](https://github.com/phmatray/ai-migration-kit/compare/v1.14.0...v1.15.0) (2026-08-27)


### Features

* **auto-dev:** investigate and guard against double-dispatching an issue ([#248](https://github.com/phmatray/ai-migration-kit/issues/248)) ([#256](https://github.com/phmatray/ai-migration-kit/issues/256)) ([8518e7c](https://github.com/phmatray/ai-migration-kit/commit/8518e7cc079737730cf0d304a99221e134ce2f8b))
* **auto-dev:** price top tier and refine tier routing ([#271](https://github.com/phmatray/ai-migration-kit/issues/271)) ([#275](https://github.com/phmatray/ai-migration-kit/issues/275)) ([529dd09](https://github.com/phmatray/ai-migration-kit/commit/529dd0931e587b17cf582e5b0035c62b5ee177e8))
* **skills:** state the untrusted-input boundary at every ingest point ([#266](https://github.com/phmatray/ai-migration-kit/issues/266)) ([#268](https://github.com/phmatray/ai-migration-kit/issues/268)) ([fb5976d](https://github.com/phmatray/ai-migration-kit/commit/fb5976d94c4a3ed3b147dd71db473fff9a80ca2c))


### Bug Fixes

* **auto-dev:** survey.sh distinguishes a failed vocabulary pipeline from a manifest with no effort axis ([#251](https://github.com/phmatray/ai-migration-kit/issues/251)) ([#262](https://github.com/phmatray/ai-migration-kit/issues/262)) ([6e1c9f9](https://github.com/phmatray/ai-migration-kit/commit/6e1c9f94d1e1ccf1eaa5d73ce71d51645d1d7eaf))
* **decisions:** R4 and R5 read what a program emits, not what its comments say ([#253](https://github.com/phmatray/ai-migration-kit/issues/253)) ([#257](https://github.com/phmatray/ai-migration-kit/issues/257)) ([0c010ef](https://github.com/phmatray/ai-migration-kit/commit/0c010efab613781c4165ec7a2945ce12eb49298b))
* **decisions:** R6 reads what a program reads, not what its comments say ([#261](https://github.com/phmatray/ai-migration-kit/issues/261)) ([#263](https://github.com/phmatray/ai-migration-kit/issues/263)) ([94055c8](https://github.com/phmatray/ai-migration-kit/commit/94055c87d5245760594aceb492043daa705153d8))
* **implement-issue:** give the three remaining guarded-git guarantees checks that can fail CI ([#161](https://github.com/phmatray/ai-migration-kit/issues/161)) ([#260](https://github.com/phmatray/ai-migration-kit/issues/260)) ([94959cd](https://github.com/phmatray/ai-migration-kit/commit/94959cd1498c53ab7b00c7c25e795d5ab46dafdd))
* **implement-issue:** make the Step 5 PR-title fallback path-first, not diff-shape-first ([#245](https://github.com/phmatray/ai-migration-kit/issues/245)) ([#255](https://github.com/phmatray/ai-migration-kit/issues/255)) ([9daaa00](https://github.com/phmatray/ai-migration-kit/commit/9daaa005f028631c788aec2906743c60722f1de5))
* **implement-issue:** resume onto an existing open PR instead of scaffolding a second one ([#214](https://github.com/phmatray/ai-migration-kit/issues/214)) ([#246](https://github.com/phmatray/ai-migration-kit/issues/246)) ([849f0b5](https://github.com/phmatray/ai-migration-kit/commit/849f0b5541a6112da34b0606ea96b85a532ba190))
* **implement-issue:** the plan-locate comment scan no longer crashes on a null comment body ([#278](https://github.com/phmatray/ai-migration-kit/issues/278)) ([#284](https://github.com/phmatray/ai-migration-kit/issues/284)) ([8e68a9b](https://github.com/phmatray/ai-migration-kit/commit/8e68a9bb7159db29eaf32d7793b2e275294c4c57))
* **implement-issue:** the PR-existence guard no longer crashes on a null PR body ([#259](https://github.com/phmatray/ai-migration-kit/issues/259)) ([#276](https://github.com/phmatray/ai-migration-kit/issues/276)) ([e77d340](https://github.com/phmatray/ai-migration-kit/commit/e77d3402a60ac82d7c341276d5480579848ca7e2))
* **repo-setup:** one home for deriving a repository's main working tree ([#125](https://github.com/phmatray/ai-migration-kit/issues/125)) ([#247](https://github.com/phmatray/ai-migration-kit/issues/247)) ([7b66a66](https://github.com/phmatray/ai-migration-kit/commit/7b66a6631c418160e80e953bbb08a45dbe4fc4ee))
* **templates:** read the coverage-guard table from the template it pins ([#141](https://github.com/phmatray/ai-migration-kit/issues/141)) ([#277](https://github.com/phmatray/ai-migration-kit/issues/277)) ([75e9041](https://github.com/phmatray/ai-migration-kit/commit/75e90418647684169af1462076b737301812d708))

## [1.14.0](https://github.com/phmatray/ai-migration-kit/compare/v1.13.1...v1.14.0) (2026-08-21)


### Features

* **decisions:** a decision gets one home, and the guard refuses a second ([#208](https://github.com/phmatray/ai-migration-kit/issues/208)) ([#241](https://github.com/phmatray/ai-migration-kit/issues/241)) ([29d07b5](https://github.com/phmatray/ai-migration-kit/commit/29d07b52c2b8c1b6100095249d268b1ba6884bac))
* **tests:** give the kit one command for the whole CI gate ([#170](https://github.com/phmatray/ai-migration-kit/issues/170)) ([#235](https://github.com/phmatray/ai-migration-kit/issues/235)) ([443f99e](https://github.com/phmatray/ai-migration-kit/commit/443f99ea4688503c0c0398aac6fd255beb8aefb4))


### Bug Fixes

* **auto-dev:** decide the takeover merge on GitHub's state, not gh's exit code ([#184](https://github.com/phmatray/ai-migration-kit/issues/184)) ([#221](https://github.com/phmatray/ai-migration-kit/issues/221)) ([1841baa](https://github.com/phmatray/ai-migration-kit/commit/1841baad62ad0f365a98ee6d71e04f192c7bd444))
* **auto-dev:** dispatch merge-pr for local cleanup after a takeover MERGED verdict ([#227](https://github.com/phmatray/ai-migration-kit/issues/227)) ([#228](https://github.com/phmatray/ai-migration-kit/issues/228)) ([7d093d3](https://github.com/phmatray/ai-migration-kit/commit/7d093d35db02ee85b5a8a40284be73e1f47c22dd))
* **auto-dev:** read the WORKTREE field on a normal MERGED report ([#234](https://github.com/phmatray/ai-migration-kit/issues/234)) ([#243](https://github.com/phmatray/ai-migration-kit/issues/243)) ([054fddf](https://github.com/phmatray/ai-migration-kit/commit/054fddfe6c90f3442499f8132bac07102e056ff0))
* **auto-dev:** survey.sh distinguishes a missing parser from a manifest with no effort axis ([#239](https://github.com/phmatray/ai-migration-kit/issues/239)) ([#249](https://github.com/phmatray/ai-migration-kit/issues/249)) ([b202433](https://github.com/phmatray/ai-migration-kit/commit/b2024332068dd628cc13b790aa680f64380ae9df))
* **auto-dev:** survey.sh names a real parser failure instead of claiming no effort axis ([#230](https://github.com/phmatray/ai-migration-kit/issues/230)) ([#236](https://github.com/phmatray/ai-migration-kit/issues/236)) ([6ec8872](https://github.com/phmatray/ai-migration-kit/commit/6ec88728b702559d5e5b258b4f6b7820f55dface))
* **ci-wiring:** refuse a wired suite that was never git-added ([#210](https://github.com/phmatray/ai-migration-kit/issues/210)) ([#225](https://github.com/phmatray/ai-migration-kit/issues/225)) ([0ae6ae7](https://github.com/phmatray/ai-migration-kit/commit/0ae6ae744e23c359eac6656f3d85fa39dca5bf41))
* **ci:** the not-executable report never claims a step doesn't invoke a suite when one does ([#238](https://github.com/phmatray/ai-migration-kit/issues/238)) ([#244](https://github.com/phmatray/ai-migration-kit/issues/244)) ([8bd1380](https://github.com/phmatray/ai-migration-kit/commit/8bd138087e0097103b76ba4f38e8329b5bd4a3b0))
* **create-issue:** derive the plan's example commit type from the issue label, not from prose-ness ([#233](https://github.com/phmatray/ai-migration-kit/issues/233)) ([#242](https://github.com/phmatray/ai-migration-kit/issues/242)) ([135ab06](https://github.com/phmatray/ai-migration-kit/commit/135ab0605728e98659264a2391e5f106d57217db))
* **merge-pr:** the can't-push fallback doesn't cover a real DIRTY conflict ([#211](https://github.com/phmatray/ai-migration-kit/issues/211)) ([#229](https://github.com/phmatray/ai-migration-kit/issues/229)) ([b6dfc97](https://github.com/phmatray/ai-migration-kit/commit/b6dfc97bee69bdaae2ef12ac7d09716428f82759))
* **merge-pr:** treat a run that has not started as pending, not as green ([#191](https://github.com/phmatray/ai-migration-kit/issues/191)) ([#226](https://github.com/phmatray/ai-migration-kit/issues/226)) ([3e70be6](https://github.com/phmatray/ai-migration-kit/commit/3e70be6751770fcd8c7ebe9b02f86b901b205bfb))
* **merge-pr:** verify and finish the remote-branch delete in Step 7 ([#185](https://github.com/phmatray/ai-migration-kit/issues/185)) ([#219](https://github.com/phmatray/ai-migration-kit/issues/219)) ([5919191](https://github.com/phmatray/ai-migration-kit/commit/5919191d465375e14b1e25b4eb67da7375d4f3be))
* **setup-repo:** a refused label write names the status it observed ([#200](https://github.com/phmatray/ai-migration-kit/issues/200)) ([#220](https://github.com/phmatray/ai-migration-kit/issues/220)) ([c87f67d](https://github.com/phmatray/ai-migration-kit/commit/c87f67d94c9e730a2a81fe2ef38ffc0a94260951))
* **setup-repo:** plan fails on placeholder areas, apply projects real ones ([#198](https://github.com/phmatray/ai-migration-kit/issues/198)) ([#237](https://github.com/phmatray/ai-migration-kit/issues/237)) ([8de9466](https://github.com/phmatray/ai-migration-kit/commit/8de94669f3d21a1775832b5a5f161c297526e3ee))
* **templates:** document the committed bundle-gate config ([#162](https://github.com/phmatray/ai-migration-kit/issues/162)) ([#232](https://github.com/phmatray/ai-migration-kit/issues/232)) ([aff82c8](https://github.com/phmatray/ai-migration-kit/commit/aff82c84706b28c14295d7ed6ae7c0c03e1a1c30))

## [1.13.1](https://github.com/phmatray/ai-migration-kit/compare/v1.13.0...v1.13.1) (2026-08-20)


### Bug Fixes

* **auto-dev:** forbid phase-1 worker waits and recognize the deferral signature ([#187](https://github.com/phmatray/ai-migration-kit/issues/187)) ([#202](https://github.com/phmatray/ai-migration-kit/issues/202)) ([e899465](https://github.com/phmatray/ai-migration-kit/commit/e899465e6b2c9dbf4f9c068d4e1d2aacb5adaf75))
* **auto-dev:** tier effort labels by the repo's own vocabulary, not a hardcoded S/M/L ([#213](https://github.com/phmatray/ai-migration-kit/issues/213)) ([#217](https://github.com/phmatray/ai-migration-kit/issues/217)) ([0beefd0](https://github.com/phmatray/ai-migration-kit/commit/0beefd0e8ddc13ad75a495414c0d7bd4bcaab1bd))
* **ci-wiring:** refuse a suite CI cannot execute, not just one nothing invokes ([#195](https://github.com/phmatray/ai-migration-kit/issues/195)) ([#205](https://github.com/phmatray/ai-migration-kit/issues/205)) ([9a32f8b](https://github.com/phmatray/ai-migration-kit/commit/9a32f8baa144baf78889dd35435b79814ebcb434))
* **implement-issue:** compare tick-plan's round-trip inside jq, not through a text-mode stdout ([#199](https://github.com/phmatray/ai-migration-kit/issues/199)) ([#207](https://github.com/phmatray/ai-migration-kit/issues/207)) ([2477f48](https://github.com/phmatray/ai-migration-kit/commit/2477f4802dba503516682b40bd286a79aed8be00))
* **merge-pr:** decide on measured divergence, not a protection-only state ([#171](https://github.com/phmatray/ai-migration-kit/issues/171)) ([#203](https://github.com/phmatray/ai-migration-kit/issues/203)) ([3372bfa](https://github.com/phmatray/ai-migration-kit/commit/3372bfabefe2d83b8a4235c18bf7da57b1b8259b))
* **scripts:** name the base every caller path is resolved against ([#143](https://github.com/phmatray/ai-migration-kit/issues/143)) ([#212](https://github.com/phmatray/ai-migration-kit/issues/212)) ([c75c3a7](https://github.com/phmatray/ai-migration-kit/commit/c75c3a755bf953cb4658d9266b4ee5e9d678a121))
* **tests:** section 8 reads code, not prose ([#159](https://github.com/phmatray/ai-migration-kit/issues/159)) ([#216](https://github.com/phmatray/ai-migration-kit/issues/216)) ([3ca3068](https://github.com/phmatray/ai-migration-kit/commit/3ca306849f377f5f03350d4b7baf68e17e922601))

## [1.13.0](https://github.com/phmatray/ai-migration-kit/compare/v1.12.1...v1.13.0) (2026-08-20)


### Features

* **setup-repo:** adopt the kit's own label taxonomy and issue forms ([#196](https://github.com/phmatray/ai-migration-kit/issues/196)) ([#197](https://github.com/phmatray/ai-migration-kit/issues/197)) ([28cf003](https://github.com/phmatray/ai-migration-kit/commit/28cf00376b32aff44821e3ba73e47bdb3a07ec01))
* **setup-repo:** plan/apply a repo's labels, issue forms and settings ([#192](https://github.com/phmatray/ai-migration-kit/issues/192)) ([#193](https://github.com/phmatray/ai-migration-kit/issues/193)) ([825cb02](https://github.com/phmatray/ai-migration-kit/commit/825cb02305948f81f8f299a97a1b53dfb2424dee))

## [1.12.1](https://github.com/phmatray/ai-migration-kit/compare/v1.12.0...v1.12.1) (2026-08-19)


### Bug Fixes

* **merge-pr:** decide the merge on GitHub's state, not gh's exit code ([#178](https://github.com/phmatray/ai-migration-kit/issues/178)) ([#181](https://github.com/phmatray/ai-migration-kit/issues/181)) ([bf4a1c8](https://github.com/phmatray/ai-migration-kit/commit/bf4a1c84468cfcc15698b1ce9e3f5614da60da03))
* **merge-pr:** judge the latest run per job, not every run on the SHA ([#91](https://github.com/phmatray/ai-migration-kit/issues/91)) ([#190](https://github.com/phmatray/ai-migration-kit/issues/190)) ([0ecb0e1](https://github.com/phmatray/ai-migration-kit/commit/0ecb0e1897bcf79ec31fe2fe39822d7cbe25353b))
* **phase-6:** collect coverage where the local flow's report reads it ([#103](https://github.com/phmatray/ai-migration-kit/issues/103)) ([#189](https://github.com/phmatray/ai-migration-kit/issues/189)) ([1d60509](https://github.com/phmatray/ai-migration-kit/commit/1d60509783ee107d9d153501e3d6524e7fd43336))
* **report:** name an unsupported screenshot format instead of raising KeyError ([#142](https://github.com/phmatray/ai-migration-kit/issues/142)) ([#183](https://github.com/phmatray/ai-migration-kit/issues/183)) ([312924b](https://github.com/phmatray/ai-migration-kit/commit/312924b4a1be715040a17ad100b62806b86b71fe))
* **tests:** followups takes its scratch from the shared library ([#160](https://github.com/phmatray/ai-migration-kit/issues/160)) ([#186](https://github.com/phmatray/ai-migration-kit/issues/186)) ([310340e](https://github.com/phmatray/ai-migration-kit/commit/310340e9a50304f2eac7ef37ab9514c549d3c686))
* **tick-plan:** bound every gh call, and make the bound release the caller ([#135](https://github.com/phmatray/ai-migration-kit/issues/135)) ([#179](https://github.com/phmatray/ai-migration-kit/issues/179)) ([7d2fbd7](https://github.com/phmatray/ai-migration-kit/commit/7d2fbd7b8dd17aa439464b88e0878b43cedb1074))


### Performance Improvements

* **audit:** read every .cs file once instead of four to five times ([#169](https://github.com/phmatray/ai-migration-kit/issues/169)) ([#182](https://github.com/phmatray/ai-migration-kit/issues/182)) ([8d1fdd6](https://github.com/phmatray/ai-migration-kit/commit/8d1fdd668b1bcfda751836652da3dce58fc67209))

## [1.12.0](https://github.com/phmatray/ai-migration-kit/compare/v1.11.0...v1.12.0) (2026-08-18)


### Features

* **skills:** give the issue lifecycle an outlet — filing bar, lineage, triage-backlog ([#176](https://github.com/phmatray/ai-migration-kit/issues/176)) ([1ebd2fc](https://github.com/phmatray/ai-migration-kit/commit/1ebd2fc35807eed1abac30be5c46e3a4931c799a))

## [1.11.0](https://github.com/phmatray/ai-migration-kit/compare/v1.10.0...v1.11.0) (2026-08-18)


### Features

* **roseline:** ship and enforce the MCP server the kit requires ([#109](https://github.com/phmatray/ai-migration-kit/issues/109)) ([#110](https://github.com/phmatray/ai-migration-kit/issues/110)) ([47f6c1e](https://github.com/phmatray/ai-migration-kit/commit/47f6c1efcef3d7045e6e82c814b8ca0ac9e09095))
* **skills:** add the auto-dev fleet supervisor and systematic-debugging ([#173](https://github.com/phmatray/ai-migration-kit/issues/173)) ([ce23b73](https://github.com/phmatray/ai-migration-kit/commit/ce23b73152029a118728a3ba64750a7b3e1e3339))
* **templates:** arm the bundle gate from a committed config, not repo state ([#96](https://github.com/phmatray/ai-migration-kit/issues/96)) ([#151](https://github.com/phmatray/ai-migration-kit/issues/151)) ([1c8947e](https://github.com/phmatray/ai-migration-kit/commit/1c8947efb221e706e3177c0266b6e550cf1286db))
* **tests:** one marker convention for every spelling of the pinned version ([#90](https://github.com/phmatray/ai-migration-kit/issues/90)) ([#152](https://github.com/phmatray/ai-migration-kit/issues/152)) ([8c4752c](https://github.com/phmatray/ai-migration-kit/commit/8c4752cbf0b252e4606af1b783c202ced1d69459))


### Bug Fixes

* **audit:** walk a first-party packages/ child however deep its project sits ([#107](https://github.com/phmatray/ai-migration-kit/issues/107)) ([#140](https://github.com/phmatray/ai-migration-kit/issues/140)) ([4a71090](https://github.com/phmatray/ai-migration-kit/commit/4a71090fe0ee073f9ce709c4ce1f6148af668e7b))
* **ci-wiring:** require a push-to-main trigger before calling a suite enforced ([#133](https://github.com/phmatray/ai-migration-kit/issues/133)) ([#138](https://github.com/phmatray/ai-migration-kit/issues/138)) ([2685961](https://github.com/phmatray/ai-migration-kit/commit/2685961bb3d875b0ef9212c5938e9175d1df5283))
* **ci:** gate every shipped path, not just skills/** ([#55](https://github.com/phmatray/ai-migration-kit/issues/55)) ([#117](https://github.com/phmatray/ai-migration-kit/issues/117)) ([fbb89ab](https://github.com/phmatray/ai-migration-kit/commit/fbb89aba76cc5281b4a5bbc5ec41bc4623bfbd72))
* **guarded-push:** read the post-push HEAD with the spelling the helper documents ([#92](https://github.com/phmatray/ai-migration-kit/issues/92)) ([#116](https://github.com/phmatray/ai-migration-kit/issues/116)) ([02bbfb6](https://github.com/phmatray/ai-migration-kit/commit/02bbfb6ba80ee5afe51d645643bbe1694b13dffb))
* **guarded-push:** tell exit 4's three conditions apart ([#93](https://github.com/phmatray/ai-migration-kit/issues/93)) ([#166](https://github.com/phmatray/ai-migration-kit/issues/166)) ([6d76efd](https://github.com/phmatray/ai-migration-kit/commit/6d76efded66972882f490f69e6ee45db4dc82756))
* **guards:** give reading HEAD's sha one home, so no receipt can name no commit ([#129](https://github.com/phmatray/ai-migration-kit/issues/129)) ([#148](https://github.com/phmatray/ai-migration-kit/issues/148)) ([55ce4a1](https://github.com/phmatray/ai-migration-kit/commit/55ce4a1bb2712e844775f1ba4290e070e8324297))
* **lib:** let first_match report a find failure that is not a missing path ([#124](https://github.com/phmatray/ai-migration-kit/issues/124)) ([#164](https://github.com/phmatray/ai-migration-kit/issues/164)) ([c215c3f](https://github.com/phmatray/ai-migration-kit/commit/c215c3f07af0348ac525f23950c7560ad2c29c07))
* **report:** name the base a relative path resolves against ([#102](https://github.com/phmatray/ai-migration-kit/issues/102)) ([#139](https://github.com/phmatray/ai-migration-kit/issues/139)) ([e7de524](https://github.com/phmatray/ai-migration-kit/commit/e7de524a3d3b636e25a2659523661e49c968cfba))
* **report:** render the measured coverage in the KPI, not a transcribed one ([#50](https://github.com/phmatray/ai-migration-kit/issues/50)) ([#106](https://github.com/phmatray/ai-migration-kit/issues/106)) ([d4b4dd6](https://github.com/phmatray/ai-migration-kit/commit/d4b4dd6bfe61835dfeee4754d8e47fc099789712))
* **roseline:** fail the gate open when the server cannot run on this host ([#112](https://github.com/phmatray/ai-migration-kit/issues/112)) ([#153](https://github.com/phmatray/ai-migration-kit/issues/153)) ([34266a8](https://github.com/phmatray/ai-migration-kit/commit/34266a8b76801f5802855416d98f7a5871b24241))
* **roseline:** probe the launcher the manifest declares, and let the user force enforcement ([#155](https://github.com/phmatray/ai-migration-kit/issues/155)) ([#167](https://github.com/phmatray/ai-migration-kit/issues/167)) ([3d6c802](https://github.com/phmatray/ai-migration-kit/commit/3d6c802ed6b8b72d5ca501064973080dfc60230a))
* **skills:** commit the repo profile and name its absence ([#157](https://github.com/phmatray/ai-migration-kit/issues/157)) ([#165](https://github.com/phmatray/ai-migration-kit/issues/165)) ([ff43e1c](https://github.com/phmatray/ai-migration-kit/commit/ff43e1cac4ff7d14bbb691bc27f32de426911fcd))
* **skills:** verify the worktree home before using a worktree, not only creating one ([#86](https://github.com/phmatray/ai-migration-kit/issues/86)) ([#120](https://github.com/phmatray/ai-migration-kit/issues/120)) ([4110889](https://github.com/phmatray/ai-migration-kit/commit/4110889b3bc755ddaca5b4e3d89d09baa5a306e1))
* **templates:** require a regular file before declaring coverage produced ([#126](https://github.com/phmatray/ai-migration-kit/issues/126)) ([#136](https://github.com/phmatray/ai-migration-kit/issues/136)) ([b51a28a](https://github.com/phmatray/ai-migration-kit/commit/b51a28a9f13a8b738c8a76f5d65dd52f1db25abe))
* **templates:** stop the coverage guard inverting under pipefail ([#97](https://github.com/phmatray/ai-migration-kit/issues/97)) ([#121](https://github.com/phmatray/ai-migration-kit/issues/121)) ([6016b4a](https://github.com/phmatray/ai-migration-kit/commit/6016b4a6f81239d81dfed8f169ecd5104a690943))
* **tests:** let every suite parse under macOS's bash 3.2 ([#131](https://github.com/phmatray/ai-migration-kit/issues/131)) ([#137](https://github.com/phmatray/ai-migration-kit/issues/137)) ([5a2ef78](https://github.com/phmatray/ai-migration-kit/commit/5a2ef78296bfb5452dbb2b37ac137f93417e5bd2))
* **tests:** let the first-match probe reach its own diagnostics ([#98](https://github.com/phmatray/ai-migration-kit/issues/98)) ([#118](https://github.com/phmatray/ai-migration-kit/issues/118)) ([fdcee07](https://github.com/phmatray/ai-migration-kit/commit/fdcee07491eec86ef96013282d502e27eb981ba7))
* **tick-plan:** return from the plan PATCH in seconds, not half an hour ([#113](https://github.com/phmatray/ai-migration-kit/issues/113)) ([#134](https://github.com/phmatray/ai-migration-kit/issues/134)) ([88a363f](https://github.com/phmatray/ai-migration-kit/commit/88a363f9860b159812c0f840fc525afaf4691e49))
* **xunit-v3:** make section 9 refuse the configs it cannot evaluate ([#99](https://github.com/phmatray/ai-migration-kit/issues/99)) ([#154](https://github.com/phmatray/ai-migration-kit/issues/154)) ([03508a1](https://github.com/phmatray/ai-migration-kit/commit/03508a1c2305ed5eec0e8c97d850164847cdb58b))


### Performance Improvements

* **audit:** probe each directory once ([#94](https://github.com/phmatray/ai-migration-kit/issues/94)) ([#147](https://github.com/phmatray/ai-migration-kit/issues/147)) ([478e749](https://github.com/phmatray/ai-migration-kit/commit/478e7490925a411a9275eadfed17a8264e1c2c7d))

## [1.10.0](https://github.com/phmatray/ai-migration-kit/compare/v1.9.1...v1.10.0) (2026-08-11)


### Features

* **audit:** report which manifest covers a vendored directory ([#100](https://github.com/phmatray/ai-migration-kit/issues/100)) ([eafbb10](https://github.com/phmatray/ai-migration-kit/commit/eafbb10e7511fe5dd8cce757f666d8fb65741e66))
* **audit:** surface vendored front-end assets no manifest covers ([#32](https://github.com/phmatray/ai-migration-kit/issues/32)) ([#64](https://github.com/phmatray/ai-migration-kit/issues/64)) ([513a754](https://github.com/phmatray/ai-migration-kit/commit/513a754c8b5044e53d9baf0990218dfea42553be))
* **ci:** gate skills changes on a releasable PR title ([#27](https://github.com/phmatray/ai-migration-kit/issues/27)) ([#29](https://github.com/phmatray/ai-migration-kit/issues/29)) ([5d6cd96](https://github.com/phmatray/ai-migration-kit/commit/5d6cd96f5472e377c9d167ea44eae53115896865))
* **implement-issue:** guard git writes against a branch switched under the task ([#26](https://github.com/phmatray/ai-migration-kit/issues/26)) ([#30](https://github.com/phmatray/ai-migration-kit/issues/30)) ([ec53b99](https://github.com/phmatray/ai-migration-kit/commit/ec53b99ffdd59118bd1ec35171a3f0762e30756f))
* **implement-issue:** guard the merge in the shared main-sync ([#41](https://github.com/phmatray/ai-migration-kit/issues/41)) ([#59](https://github.com/phmatray/ai-migration-kit/issues/59)) ([9e0dc81](https://github.com/phmatray/ai-migration-kit/commit/9e0dc81f1559083c248082b31ef1a2b3c106e45c))
* **legacy-upgrade:** gate the xunit v2 to v3 move as an explicit phase-5 decision ([#12](https://github.com/phmatray/ai-migration-kit/issues/12)) ([#13](https://github.com/phmatray/ai-migration-kit/issues/13)) ([3269749](https://github.com/phmatray/ai-migration-kit/commit/326974934f47cabbac29f9eec72eba378b78dd50))
* **merge-pr:** triage follow-ups by root cause instead of filing every finding ([#108](https://github.com/phmatray/ai-migration-kit/issues/108)) ([cab02af](https://github.com/phmatray/ai-migration-kit/commit/cab02af9c587fc9ea0a2b779639eeef6f2cd8bf1))
* **renovate:** track the xunit.v3 and coverage pins in apply-transform.py ([#36](https://github.com/phmatray/ai-migration-kit/issues/36)) ([#54](https://github.com/phmatray/ai-migration-kit/issues/54)) ([b7babb7](https://github.com/phmatray/ai-migration-kit/commit/b7babb74ef3776dfcc69f84e57b3e66dd319f864))
* **report:** aggregate several cobertura reports, or a whole coverage/ directory ([87caeba](https://github.com/phmatray/ai-migration-kit/commit/87caeba772a997a7b36d57748682185785996b06))
* **templates:** ship the bundle-drift gate as if-gated live steps ([#70](https://github.com/phmatray/ai-migration-kit/issues/70)) ([#87](https://github.com/phmatray/ai-migration-kit/issues/87)) ([a4a0127](https://github.com/phmatray/ai-migration-kit/commit/a4a0127a60c795b6bcf8b0fe32a612224937b803))
* **xunit-v3:** enforce the MTP/coverage version pairing ([#18](https://github.com/phmatray/ai-migration-kit/issues/18)) ([#22](https://github.com/phmatray/ai-migration-kit/issues/22)) ([d0316a3](https://github.com/phmatray/ai-migration-kit/commit/d0316a30e02da2c7ce868ce8c7c9db7274e7fbdd))
* **xunit-v3:** model the whole Microsoft.Testing family in the pairing map ([#38](https://github.com/phmatray/ai-migration-kit/issues/38)) ([#53](https://github.com/phmatray/ai-migration-kit/issues/53)) ([3798ed0](https://github.com/phmatray/ai-migration-kit/commit/3798ed04c44538ea155bb512cff26c0eb3c623c3))


### Bug Fixes

* **audit:** one traversal rule for every inventory key ([#65](https://github.com/phmatray/ai-migration-kit/issues/65)) ([#80](https://github.com/phmatray/ai-migration-kit/issues/80)) ([0f03818](https://github.com/phmatray/ai-migration-kit/commit/0f03818fc3d4ff7f21e34373620de03e8a347dbb))
* **guarded-push:** parse ls-remote stdout, not the warning on stderr ([#47](https://github.com/phmatray/ai-migration-kit/issues/47)) ([#88](https://github.com/phmatray/ai-migration-kit/issues/88)) ([79d63e0](https://github.com/phmatray/ai-migration-kit/commit/79d63e007a231670b9a5e74388b8fffc9c7b9bd5))
* **implement-issue:** fold the merge guard into the shared branch assertion ([#44](https://github.com/phmatray/ai-migration-kit/issues/44)) ([#84](https://github.com/phmatray/ai-migration-kit/issues/84)) ([3b452ad](https://github.com/phmatray/ai-migration-kit/commit/3b452ad87485f7674bbcb2c763137c01fcc1a318))
* **implement-issue:** give the branch assertion a single home ([#44](https://github.com/phmatray/ai-migration-kit/issues/44)) ([#62](https://github.com/phmatray/ai-migration-kit/issues/62)) ([27a8c73](https://github.com/phmatray/ai-migration-kit/commit/27a8c73f109482ab3f40dd509fbf6430765dcf1c))
* **renovate:** block the frozen fixture without hiding it from vulnerability alerts ([#40](https://github.com/phmatray/ai-migration-kit/issues/40)) ([7573da1](https://github.com/phmatray/ai-migration-kit/commit/7573da168db1305540315158ebdc11019a0e3101))
* **report:** make the coverage path in the template actually resolve ([#49](https://github.com/phmatray/ai-migration-kit/issues/49)) ([#95](https://github.com/phmatray/ai-migration-kit/issues/95)) ([ae83344](https://github.com/phmatray/ai-migration-kit/commit/ae833443bf886885f8d834a6023010cea63b1c57))
* **skills:** drop the per-skill version that release-please does not maintain ([#16](https://github.com/phmatray/ai-migration-kit/issues/16)) ([#20](https://github.com/phmatray/ai-migration-kit/issues/20)) ([320971e](https://github.com/phmatray/ai-migration-kit/commit/320971e55d8f40955c3ef8faf2dd108d5a898c6a))
* **skills:** stage only the merge resolution when completing a sync ([#68](https://github.com/phmatray/ai-migration-kit/issues/68)) ([#75](https://github.com/phmatray/ai-migration-kit/issues/75)) ([3dd0d70](https://github.com/phmatray/ai-migration-kit/commit/3dd0d70af511c262ae495fc3efbe7d03c21b2c28))
* **skills:** verify the worktree home is ignored before creating one ([#71](https://github.com/phmatray/ai-migration-kit/issues/71)) ([#77](https://github.com/phmatray/ai-migration-kit/issues/77)) ([564fbab](https://github.com/phmatray/ai-migration-kit/commit/564fbabc2f086654b62b708964d23623299157b8))
* **templates:** collect the MTP log that explains a coverage failure ([#74](https://github.com/phmatray/ai-migration-kit/issues/74)) ([#81](https://github.com/phmatray/ai-migration-kit/issues/81)) ([633750a](https://github.com/phmatray/ai-migration-kit/commit/633750a722e43d299071df98f365482a0fbc3ede))
* **templates:** emit one cobertura per test project under MTP ([#17](https://github.com/phmatray/ai-migration-kit/issues/17)) ([#23](https://github.com/phmatray/ai-migration-kit/issues/23)) ([87caeba](https://github.com/phmatray/ai-migration-kit/commit/87caeba772a997a7b36d57748682185785996b06))
* **templates:** keep cobertura coverage produced under the MTP test platform ([3269749](https://github.com/phmatray/ai-migration-kit/commit/326974934f47cabbac29f9eec72eba378b78dd50))
* **templates:** manage and un-stale the workflow templates the kit ships ([#35](https://github.com/phmatray/ai-migration-kit/issues/35)) ([#46](https://github.com/phmatray/ai-migration-kit/issues/46)) ([54b5fbe](https://github.com/phmatray/ai-migration-kit/commit/54b5fbe294c5dde7e6bf734b59f8b3f09ec673f4))
* **tests:** stop a SIGPIPE'd find from skipping the checks it feeds ([#48](https://github.com/phmatray/ai-migration-kit/issues/48)) ([#89](https://github.com/phmatray/ai-migration-kit/issues/89)) ([640c267](https://github.com/phmatray/ai-migration-kit/commit/640c26781057bd53904a29008387d0d9b39a6bc9))
* **xunit-v3:** assert what Renovate does with the config, not what it says ([#67](https://github.com/phmatray/ai-migration-kit/issues/67)) ([#76](https://github.com/phmatray/ai-migration-kit/issues/76)) ([b0e0777](https://github.com/phmatray/ai-migration-kit/commit/b0e0777ea86c5414491cd9e8b5df7b8aa5dc64e9))
* **xunit-v3:** derive the coverage literals and pin the reference to the transform ([#69](https://github.com/phmatray/ai-migration-kit/issues/69)) ([#85](https://github.com/phmatray/ai-migration-kit/issues/85)) ([a321d72](https://github.com/phmatray/ai-migration-kit/commit/a321d72603df4ba3812c3a2bd4de66b73f09787c))

## [1.9.1] — 2026-08-10

Correctif de **propagation**, entré sur `main` par la PR #7 sans tag ni entrée de changelog — les
deux sont posés rétroactivement le 2026-08-10, en même temps que l'installation de release-please.

### Corrigé
- **Le garde-fou `tick-plan` de la PR #5 est effectivement livré.** Les skills sont consommées via
  le marketplace, et la copie installée est un **cache d'installation clé par version**, pas une vue
  vive du dépôt : mesuré sur l'issue #6, amener le clone du marketplace sur un commit contenant le
  correctif laisse le cache chargé **inchangé**. Un correctif mergé sans bump de
  `.claude-plugin/plugin.json` atteint donc **zéro consommateur**, tout en ayant l'apparence exacte
  d'une release réussie — CI verte, commit sur `main`. C'est ce qui était arrivé à la PR #5.

## [1.9.0] — 2026-07-23

Porte de **verdict de fin de phase 1** — les deux items du backlog dont le déclencheur a sauté le
même jour (2026-07-23), livrés comme **un seul changement** parce que ce sont les deux bords d'un
même classifieur (même étape, symptômes inverses). En une ligne : la phase 1 devient une vraie
porte — elle classe la cible avant de laisser `/migrate` avancer, au lieu de toujours dire « go ».

### Ajouté
- **`verdict: <ALREADY_MODERN | RED_BY_TFM_LAG | NORMAL>` en tête de `migration/assessment.md`**
  (`phase-1-assess.md` étape 6) — calculé en fin de phase 1, c'est ce sur quoi `/migrate` branche
  (SKILL.md : table du pipeline, contrat d'artefacts, Scope variants).
- **`ALREADY_MODERN` → stop après la phase 1** (dogfood `Atypical-Consulting/StaticWGen`, net10
  partout, paquets tenus par Renovate) : plus de phase 3 (retarget) à vide, ni de phase 7 déployant
  du Blazor sur Pages pour un outil CLI sans cible web. Routé vers `/migrate-verify` — moderne ≠
  propre : le restore vert de StaticWGen a remonté `NU1903` (vuln transitive haute). Troisième
  profil « saine, rien à migrer » ajouté à `audit-executive.md` (`/migrate-audit`).
- **`RED_BY_TFM_LAG` → le retarget EST le prérequis du baseline** (vague `phmatray/DotnetChain`,
  net9→net10, PR #64) : quand un robot pousse les paquets au-delà du TFM (`NU1202`, restore
  impossible avant migration), la porte « baseline vert d'abord » ne peut pas tenir. La phase 2
  consigne le baseline comme *différé* (`phase-2-baseline.md` étape 1) et la phase 3 capte le
  premier vert post-retarget comme baseline enregistré (`phase-3-retarget.md` étape 6).
- **Verrou de régression** : les deux cas dogfood (StaticWGen, DotnetChain) épinglés en fixtures
  documentées dans `phase-1-assess.md` (« Verdict fixtures ») — re-dériver un autre verdict pour
  l'une de ces signatures est une régression, pas un jugement.

### Modifié
- `commands/migrate.md` et `commands/migrate-assess.md` : branchement et routage explicites selon
  le verdict (aucune commande de portée nouvelle — la plomberie `/migrate-assess` = phase 1 seule
  et `/migrate-verify` = phase 6 seule existait déjà).
- `docs/backlog.md` : les deux items implémentés sortent du backlog (les cinq à déclencheur non
  atteint et les non-adoptions restent).

## [1.8.0] — 2026-07-23

Implémentation intégrale de la revue jobs du jour (`reviews/2026-07-23-jobs/`, lentille Arbor :
quelles disciplines du framework de recherche RUC-NLPIR/Arbor méritent d'entrer dans un pipeline
déterministe — et lesquelles refuser) : les 6 findings résolus. En une ligne : le kit adopte les
ceintures de sécurité d'Arbor (reprise, convergence, temps mesuré, rétropropagation), et refuse
son volant (l'exploration arborescente).

### Ajouté
- **Reprise d'un `/migrate` interrompu** (le `--resume` d'Arbor) : le pipeline détecte le dossier
  `migration/` et les commits de porte (leur message nomme la phase — règle 4, les artefacts
  confirment), annonce le point de reprise et ré-entre à la phase qui suit la dernière porte
  verte ; une phase verte n'est jamais rejouée (SKILL.md Scope variants + Common issues,
  commande `/migrate`).
- **Règle 9 — la remédiation doit converger** (la politique de budget d'Arbor) : deux passes de
  phase 4 consécutives sans baisse du compte d'erreurs = stop, retour à la dernière porte verte,
  blocage consigné au rapport (diagnostics restants groupés par id), décision au propriétaire
  (SKILL.md + phase-4-remediate + Common issues).
- **Chronologie du pipeline mesurée** : `migration/report.json` porte `phases[]` (début/fin/minutes
  par phase), **dérivée des commits de porte** (`git log` de la branche de migration, phase-6-verify
  §6) — le « temps pipeline mesuré » du README devient un fait généré, jamais un chronomètre
  humain ; `report-dashboard.py` rend la carte « Chronologie du pipeline » avec le total calculé
  (test golden étendu).
- **La rétropropagation devient un contrat** (le backpropagate d'Arbor) : la phase 7 se clôt par
  une entrée `lessons` dans `report.json` — référence du changement appliqué au kit ou « rien à
  apprendre de cette vague » explicite ; une vague sans entrée leçons est incomplète (règle 8,
  delivery-playbook étape 9, report-template) ; le dashboard rend la carte « Leçons de la vague »
  (test golden étendu).
- **Audit de portefeuille en éventail** : `/migrate-audit` multi-apps documente le fan-out — un
  sous-agent par app (les inventaires sont indépendants par construction), l'orchestrateur ne
  garde que la synthèse portefeuille. Aucun script modifié.
- **Non-adoptions consignées** (docs/backlog.md, section « décisions fermées ») : arbre
  d'hypothèses / Idea Tree, modes d'interaction, novelty search — refusés avec justification
  (pipeline déterministe ≠ recherche exploratoire) et condition de réouverture, pour que la
  décision survive aux sessions.

## [1.7.0] — 2026-07-23

Implémentation intégrale de la seconde revue elon du jour (`reviews/2026-07-23-elon-2/`, lentille
cohérence / workflow prédictif / déterminisme) : les 9 findings résolus.

### Modifié
- **Le pipeline finit en production, partout** : `/migrate` couvre officiellement les phases 1–7
  (la contradiction commande « 1–6 » / règle 8 « livrée = en production » est tranchée) ; la marque
  « six-phase » corrigée en « seven-phase » (README, plugin.json, description du skill) ; une app
  sans cible de production clôt la phase 7 par la décision propriétaire consignée — documentée,
  jamais silencieuse.
- **Ancrage `<kit>` des scripts et templates** : `legacy-upgrade` et `followups` résolvent
  désormais tout chemin du kit depuis `<skill-dir>/../..` (comme `get-repo-profile` le faisait
  déjà), jamais depuis le CWD — une installation marketplace fonctionne à froid. Verrouillé en CI
  par un step « foreign working directory » (préflight, inventaire, followups, repo-profile
  exécutés depuis un répertoire étranger).
- **`requirements.json` exprime la requiredness par skill** : champ `requiredBy` (+ `token`) sur
  gh CLI (create-issue, implement-issue, merge-pr), superpowers (create-issue, implement-issue)
  et code-review (implement-issue) — la contradiction littérale « level: recommande / when:
  requis » est éliminée. Le préflight affiche `[hard-required by: …]` et émet `requiredBy` en
  JSON ; cross-check manifest ↔ frontmatter `compatibility` en CI (check-frontmatter.py).
- **Le préflight émet son JSON via python3** (échappement réel, plus de printf artisanal ni de
  séparateur `|` collisionnable — la dette backlog « échappement JSON des hints » est levée) ;
  sortie et statuts en anglais (`ok`/`missing`/`absent`/`unknown`, niveaux
  `required`/`recommended`).
- **Anglais sur la surface distribuée** : SKILL.md `followups` et `legacy-upgrade` unifiés en
  anglais (fini le FR/EN au milieu du fichier), commandes `migrate-audit` et `migrate-followups`
  traduites. Restent français par décision : CHANGELOG, études de cas, sortie de `followups.py`
  (elle alimente les rapports français) et 4 references de `legacy-upgrade` (dette backloguée
  avec déclencheur).
- `create-issue` ne prépare plus l'identité de commit (il ne committe jamais) ; `plugin.json`
  n'énumère plus les phases (une string marketing qui répète le README dérive).

### Ajouté
- **`tests/repo-profile/test.sh`** : golden test du seul script du kit qui n'en avait pas —
  `show` (profil présent / NO_PROFILE exit 3), `detect` hors git (exit 4), et le contrat TODO
  sur un repo minimal (sections présentes + fallbacks réellement déclenchés).
- **`implement-issue` : réconciliation du miroir PR à la reprise** — le PATCH de l'issue et
  l'édition du corps de la PR ne sont pas atomiques ; la boucle du Step 6 resynchronise
  désormais la liste `### Plan` depuis l'état canonique de l'issue avant de reprendre.
- Note d'honnêteté dans les 6 listes `tests/skills/*.triggers.md` : la CI garde la présence,
  le banc lui-même est manuel (entrée backlog avec déclencheur : prochaine modification de
  description).

### Corrigé
- **`repo-profile.sh` : fallbacks TODO morts** — `grep … | head || echo TODO` ne peut jamais
  tirer (head sort à 0 sur entrée vide) ; toutes les sondes passent par `emit_or_todo()` (une
  seule convention, `probe()` supprimée) et le contrat « champ indétectable ⇒ ligne TODO » est
  tenu (gardé par le nouveau golden test).

## [1.6.0] — 2026-07-23

Solution unifiée : le kit intègre les skills issue/PR génériques, et les prérequis ont une
source unique.

### Ajouté
- **`requirements.json`** : source unique des prérequis (outils, MCP requis/recommandés, skills de
  session — y compris les dépendances des skills issue/PR : gh, superpowers, code-review).
  `scripts/preflight.sh` la lit désormais au lieu d'embarquer sa propre liste ; README et la
  phase 0 du SKILL.md y pointent au lieu de dupliquer l'énumération (trois copies → une).
  Testé en CI (`tests/preflight/test.sh` : JSON valide, couverture intégrale du manifest, échec
  réel sur REQUIS manquant).
- **Quatre skills issue/PR génériques intégrés au kit** — `skills/create-issue` (issue semée
  brainstorm → spec → plan cochable), `skills/implement-issue` (plan → PR draft → ready, un commit
  par tâche), `skills/merge-pr` (attente CI, boucle de corrections, squash-merge, suivis),
  `skills/get-repo-profile` (générateur du profil par repo) + `skills/_shared`. Importés d'un autre
  projet puis **dé-spécifiés** : descriptions, numéros d'issues CI, liens ADR, taxonomie de labels
  et fichiers temporaires propres au repo d'origine retirés — tout fait spécifique au repo vit dans
  le repo-profile (`.claude/skills/repo-profile.md`), comme l'abstraction le promettait. Le restant
  de l'import (orchestrateur de flotte, lanceur d'IDE, profil du repo d'origine, settings.json aux
  hooks inexistants) n'a pas été retenu.
- **Pont `followups` → `create-issue`** : un suivi qui mérite un ticket se convertit en issue
  GitHub via le skill du kit ; l'entrée du `report.json` garde l'URL de l'issue — jamais de liste
  parallèle (SKILL.md `followups` + règle 8).
- **Conformité au guide Anthropic des skills** (revue elon du 2026-07-23, rapport dans
  `reviews/2026-07-23-elon/`) : les 6 descriptions tiennent sous la limite de 1024 caractères du
  standard (3 compressées) et portent des déclencheurs bilingues FR/EN ; frontmatter complété sur
  les 6 skills (`license: MIT`, `compatibility` — miroir distribution de `requirements.json` —,
  `metadata.author/version/suite`) ; fichier `LICENSE` (MIT) ; **tests de déclenchement par skill**
  (`tests/skills/<name>.triggers.md`, listes should / should-not en anglais) gardés en CI par
  `tests/skills/check-frontmatter.py` (limites du guide + listes présentes) ; dédoublonnage
  SKILL.md ↔ references sur `implement-issue` et `merge-pr` (les recettes gh/jq vivent une seule
  fois, dans les references) ; sections **Troubleshooting** (erreur → cause → solution) dans
  `legacy-upgrade` et les references lifecycle.
- **`ARCHITECTURE.md`** : graphe d'appels des skills (mermaid, rendu par GitHub), graphe des
  dépendances externes (MCP, plugins, outils), matrice de dépendances par skill et table des
  sources uniques par préoccupation.

## [1.5.0] — 2026-07-23

Le pipeline rend compte de sa queue : suivis consolidés et mis à jour à la source.

### Ajouté
- **Skill `followups` + commande `/migrate-followups`** : consolide les suivis ouverts de tous
  les repos migrés (`next_steps`/`deferred` des `migration/report.json` + backlog du kit) —
  décisions propriétaire d'abord, tâches par effort croissant — et définit les protocoles de
  mise à jour **à la source** : « fait » (retrait + coche + dashboard + commit), « clos par
  décision » (bascule en `deferred` datée), ajout a posteriori. Jamais de liste parallèle.
- **`scripts/followups.py`** : l'agrégateur (lecture seule), sortie markdown triée ou `--json` ;
  testé en CI (tri avec virgule française « ~0,5 h », owner-first, backlog, chemin d'erreur).
- La phase 7 se conclut par un passage de `followups` (SKILL.md règle 8).

Validé au banc skill-creator : 3 cas (consolidation, marquer fait, clore par décision) en
double aveugle avec/sans skill — **16/16 assertions avec le skill contre 12/16 sans** (la
référence invente un tableau `closed` hors schéma, oublie le dashboard, réinvente le tri) ;
puis test réel en lecture seule sur winrt-sokoban-blazor.

## [1.4.1] — 2026-07-23

Leçons de la vague 3 (pokedexg : UWP 2016 + « backend » netcoreapp1.0 → Blazor WASM + API statique).

### Ajouté
- **Détection des projets zombies** dans `audit-inventory.sh` : `projectDetails[].targetFramework`
  (lu du csproj) et `zombie: true` quand un TFM ancien (netcoreapp1/2, netstandard1, PCL, UAP)
  reçoit des paquets 10+ — un robot de mise à jour n'est pas un signe de vie. L'audit de pokedexg
  avait pris un webservice netcoreapp1.0 arrosé par Renovate pour un « backend déjà moderne ».
- **Prémisses vérifiées, jamais déduites** (audit-executive.md) : TFM lus des csproj, tests
  prouvés par attributs (jamais par un nom de projet dans une .sln — référence pendante chez
  pokedexg), flux de données prouvé par l'appelant (HttpClient) avant d'écrire « branché ».
- **Cinq protocoles vague 3** (rewrite-playbook) : SQL legacy sur SQLite moderne (ON réordonné,
  RECONSTRUCTION) ; assets hors projet copiés par cible MSBuild — jamais `Content Link`
  (servi 200/0 octet) — et build avant publish ; cascade Tailwind (`@layer base`) ; précache
  service worker = contrat d'une app installée ; hors-ligne prouvé en tuant le serveur quand
  la production n'existe pas encore.

### Corrigé
- **`report-dashboard.py` écrit sa sortie à côté du report.json** (plus jamais dans le cwd —
  le dashboard de la vague 3 avait atterri à la racine du repo migré) ; test golden étendu.

## [1.4.0] — 2026-07-23

Le pipeline vérifie désormais ses promesses (review post-vague 2).

### Ajouté
- **`scripts/contrast-check.py`** : contraste WCAG 2.1 mesuré (jamais estimé à l'œil) pour toutes
  les paires encre/fond, thèmes clair et sombre — obligatoire avant de livrer une UI réécrite
  (rewrite-playbook) ; testé en CI (chemins succès ET échec).
- **Job `verify` dans `templates/deploy-pages-blazor.yml`** : smoke test post-déploiement — la
  racine et une route profonde doivent servir le CONTENU de l'app (`SMOKE_MARKER`,
  `SMOKE_DEEP_ROUTE`), jamais le seul code HTTP ; `SMOKE_MARKER` vide = garde-fou bloquant.
- **Détection des projets-squelettes** dans `audit-inventory.sh` (`projectDetails`,
  `skeletonProjects`) : un échafaudage vide ne compte plus dans la logique portable — leçon
  vague 2 (5 projets « en couches » vides avaient gonflé l'audit).
- **Double chiffrage obligatoire** dans l'audit (audit-executive.md) : jours-équipe-humaine
  (coût évité) **et** minutes-pipeline (prix réel, calibré sur les vagues mesurées).
- **Protocole hors-ligne PWA** (rewrite-playbook) : le hors-ligne se teste réseau coupé, jamais
  ne se déclare ; piège `caches.match('index.html')` → utiliser `caches.match('./')` d'abord.
- `docs/backlog.md` : dettes notées avec leur déclencheur (sync des artefacts copiés, timeout
  préflight, échappement JSON).

## [1.3.2] — 2026-07-23

Leçons de la vague 2 (fleurs-du-mal, migrée en ~30 min pour 18 j estimés).

### Ajouté
- **Protocole d'inventaire des assets binaires locaux** (rewrite-playbook) : regarder chaque
  asset embarqué avant de dessiner l'UI — le dessin original d'une artiste, cœur du design 2014,
  avait failli être perdu parce que les seules images *visibles* étaient des URLs externes mortes.
  Port octet pour octet + crédit d'artiste (décision propriétaire si le nom manque).

### Corrigé
- `report-dashboard.py` : les chemins du `report.json` (cobertura, capture) se résolvent
  **relativement au JSON**, plus au répertoire courant ; le test golden le prouve en tournant
  depuis la racine du repo.
- Playbook de livraison : la vérification de la route profonde teste le **contenu**, pas le code
  HTTP — le fallback 404.html de GitHub Pages sert l'app avec un statut 404 (faux négatif sinon).

## [1.3.1] — 2026-07-23

Durcissement issu de la review v1.3.0 : les outils rendus obligatoires par la règle 7 deviennent
infaillibles et testés.

### Ajouté
- **Test golden du générateur de rapport** (`tests/report-dashboard/`) : fixture `report.json` +
  cobertura → HTML, assertions sur les valeurs calculées (couverture par classe, exclusions,
  autonomie du document, thème sombre). Exécuté en CI ; remplace le simple `py_compile`.
- **`preflight.sh --json`** : sortie machine des checks, à verser dans `migration/report.json`
  sans recopie manuelle.
- **Garde-fous dans `templates/deploy-pages-blazor.yml`** : échec explicite si `BASE_PATH` reste
  le placeholder `/REPO_NAME/`, et vérification post-`sed` que le `<base href>` a réellement été
  réécrit — fini le déploiement vert avec page blanche en prod.
- **Validation YAML des templates** dans la CI du kit.
- Ce CHANGELOG.

### Modifié
- Préflight : le SDK .NET est vérifié par **comparaison numérique du major (>= 8)** au lieu de
  l'énumération `8|9|10` qui aurait bloqué à tort les SDK futurs (.NET 11+).
- Préflight : un serveur MCP **configuré mais non connecté ne passe plus** — l'état de santé de
  `claude mcp list` est vérifié, pas seulement la présence du nom.
- Template de déploiement : le `sed` du base href tolère les variantes du template Blazor
  (`<base href="/">`, `"/"/>`, `"/" />`) ; en-tête enrichi (409 Pages = déjà activé,
  `dotnet-version` à ajuster au TFM cible).
- Playbook de livraison : activation Pages documentée idempotente (`409` = succès, continuer).

### Supprimé
- Les « indices disque » de présence des skills dans le préflight : un check dont le script
  lui-même disait « la vérité est ailleurs » est du bruit. La responsabilité vit à l'étape 2 de
  la phase 0 (SKILL.md) : l'agent confirme ses capacités de session.

## [1.3.0] — 2026-07-22

Le pipeline devient déterministe et auto-vérifié.

### Ajouté
- **Phase 0 préflight** (`scripts/preflight.sh`) : requis bloquants (dotnet, git, python3,
  RoselineMCP), recommandés à dégradation bruyante (context7, gh, node, Chrome headless).
- **Phase 7 Deliver** + `references/delivery-playbook.md` : une migration n'est finie
  qu'en production vérifiée (branche par défaut, désarchivage, Pages, route profonde + capture).
- **`templates/deploy-pages-blazor.yml`** : déploiement Blazor WASM → GitHub Pages paramétré
  (SOLUTION, WEB_PROJECT, BASE_PATH), fallback SPA et `.nojekyll` intégrés.
- Règles 7 (« scripts et templates du kit obligatoires ») et 8 (« livrée = en production »).
- Protocoles vague 1 dans le rewrite-playbook : namespaces conservés, en-têtes RECONSTRUCTION,
  tests historiques jamais verts (skip documenté + wrapper + tests d'intention), `<NoWarn>` d'époque.

## [1.2.0] — 2026-07-22

Industrialisation post-vague 1.

### Ajouté
- **`scripts/report-dashboard.py`** : générateur du dashboard exécutif de migration
  (`report.json` + cobertura + capture → HTML autonome, thème clair/sombre, palette validée).
- **`templates/ci-dotnet.yml`** : CI réutilisable (tests + couverture), variable `SOLUTION`
  pour les repos à plusieurs `.sln` (leçon MSB1011 de chords).
- CI du kit (fixture LegacyShop, manifestes, invariants des guides de phase).
- Publication du repo (github.com/phmatray/ai-migration-kit) et cas d'étude portfolio WinRT
  avec deux migrations en production (sokoban, chords).

## [1.1.0] — 2026-07-22

### Ajouté
- **`/migrate-audit`** : audit exécutif lecture seule, chiffré (formule d'effort transparente,
  ±30 %), portfolio multi-apps avec matrice valeur/effort et première vague recommandée.
- `scripts/audit-inventory.sh` : inventaire JSON reproductible (ère technologique, surface XAML,
  clusters d'API plateforme, LOC logique vs code-behind).
- Rewrite-playbook (port-characterize-wrap) pour les plateformes mortes (WinRT/UWP → Blazor).
- Règle 6 : le livrable ne raconte jamais sa migration.

## [1.0.0] — 2026-07-22

### Ajouté
- Pipeline six phases porté par RoselineMCP : Assess, Baseline, Retarget, Remediate, Modernize,
  Verify — portes vertes obligatoires, mutations preview-first, branche `migration/<date>`.
- Commandes `/migrate`, `/migrate-assess`, `/migrate-verify`.
- Fixture `samples/LegacyShop` (net6.0, volontairement legacy) et démo vérifiée
  (`docs/demo-walkthrough.md`).
