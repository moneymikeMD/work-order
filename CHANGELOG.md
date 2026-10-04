# Changelog

## [1.10.0](https://github.com/moneymikeMD/work-order/compare/v1.9.0...v1.10.0) (2026-10-04)


### Features

* **reference:** accept repo:path as canonical cross-repo touches form (WO-94) ([#78](https://github.com/moneymikeMD/work-order/issues/78)) ([3b0d94a](https://github.com/moneymikeMD/work-order/commit/3b0d94a28634b78168318e98e02a8346a6c53703))

## [1.9.0](https://github.com/moneymikeMD/work-order/compare/v1.8.0...v1.9.0) (2026-10-01)


### Features

* **jira:** provider.sh link and unlink verbs for Blocks links (WO-95) ([#73](https://github.com/moneymikeMD/work-order/issues/73)) ([f5c0a3a](https://github.com/moneymikeMD/work-order/commit/f5c0a3a24278cbac6a2260339c9a6b8af7ed2d57))
* **jira:** provider.sh transition --outcome and duplicate-safe create (WO-96) ([#76](https://github.com/moneymikeMD/work-order/issues/76)) ([ba12351](https://github.com/moneymikeMD/work-order/commit/ba12351d05b36b5b387a994d1c8567c4a4181c03))

## [1.8.0](https://github.com/moneymikeMD/work-order/compare/v1.7.0...v1.8.0) (2026-09-27)


### Features

* **conformance:** treat Epics and Sub-tasks as groupings, not tickets (WO-76) ([#57](https://github.com/moneymikeMD/work-order/issues/57)) ([5820f6e](https://github.com/moneymikeMD/work-order/commit/5820f6efd764db7c878c8813b1a0455bd3ec9865))
* **jira:** converge the Universal workflows and shared scheme from a repo spec (WO-71) ([#61](https://github.com/moneymikeMD/work-order/issues/61)) ([5716c24](https://github.com/moneymikeMD/work-order/commit/5716c240a699dcce3d6084070637ee4ebfc56ed7))
* **jira:** provisioning assigns the shared Universal scheme instead of copying a workflow per project (WO-79) ([#60](https://github.com/moneymikeMD/work-order/issues/60)) ([a5ba0c6](https://github.com/moneymikeMD/work-order/commit/a5ba0c65045cf6fae9987b687c17f161e5461e37))
* **jira:** retire the To Do and Done read-only aliases (WO-81) ([#68](https://github.com/moneymikeMD/work-order/issues/68)) ([483b5e3](https://github.com/moneymikeMD/work-order/commit/483b5e3204da8d9390e8f7169bb13c320b575f24))
* **jira:** shared Universal issue type schemes, screens and categories in two tiers (WO-89) ([#69](https://github.com/moneymikeMD/work-order/issues/69)) ([78fe9e1](https://github.com/moneymikeMD/work-order/commit/78fe9e132862ab27e42a1cf8e32627ed33bebf87))
* **jira:** universal-switch.sh moves a project onto the Universal scheme (WO-77) ([#62](https://github.com/moneymikeMD/work-order/issues/62)) ([633764c](https://github.com/moneymikeMD/work-order/commit/633764c469f8266d7b887ec6a76edc7ce72d51a2))
* **jira:** workflows set and clear resolution (WO-91) ([#70](https://github.com/moneymikeMD/work-order/issues/70)) ([34e6734](https://github.com/moneymikeMD/work-order/commit/34e673414b1ad6410448b71b703eb6107a3ebcf4))


### Bug Fixes

* **jira:** declare resolution-setting actions with mode replace (WO-91) ([#71](https://github.com/moneymikeMD/work-order/issues/71)) ([d15664d](https://github.com/moneymikeMD/work-order/commit/d15664dec629b0c96ff8c6176188ecf3f0f9e162))
* **jira:** universal-switch maps every issue type the old scheme names (WO-80) ([#65](https://github.com/moneymikeMD/work-order/issues/65)) ([1cd8f72](https://github.com/moneymikeMD/work-order/commit/1cd8f72a6dbe7fd9cc0a1990755634e3fae9d834))
* **jira:** universal-switch maps every status the target workflow lacks (WO-78) ([#63](https://github.com/moneymikeMD/work-order/issues/63)) ([b517a47](https://github.com/moneymikeMD/work-order/commit/b517a47a3239cb66f1c503bd067bebcd1e900beb))
* **jira:** universal-switch retries a delete while a workflow task holds the lock (WO-80) ([#67](https://github.com/moneymikeMD/work-order/issues/67)) ([9c7442c](https://github.com/moneymikeMD/work-order/commit/9c7442c09332a9a02e999f272f7943599deb9b3b))
* **jira:** universal-switch retries while another Jira task holds the switch (WO-80) ([#66](https://github.com/moneymikeMD/work-order/issues/66)) ([cbe126f](https://github.com/moneymikeMD/work-order/commit/cbe126f9a5588a16a35ad69b882d044f80dcdfa0))
* **jira:** universal-switch waits on the project's scheme when the 303 carries no task (WO-78) ([#64](https://github.com/moneymikeMD/work-order/issues/64)) ([0171159](https://github.com/moneymikeMD/work-order/commit/0171159928f1a8bf22b24b68cac473b58d602baa))

## [1.7.0](https://github.com/moneymikeMD/work-order/compare/v1.6.0...v1.7.0) (2026-09-24)


### Features

* blocked_by_external gives a cross-repo blocker a structured home (WO-70) ([#53](https://github.com/moneymikeMD/work-order/issues/53)) ([fe16872](https://github.com/moneymikeMD/work-order/commit/fe1687255f85bf6966e8df6d0eabfeadbd7776a7))
* lint --scope gates the exit code on the named tickets only (WO-69) ([#52](https://github.com/moneymikeMD/work-order/issues/52)) ([922a768](https://github.com/moneymikeMD/work-order/commit/922a7686a8178638b9c7ca44db5e69e7f3fa8182))
* remove waves and preflight from reference/issues.py (WO-73) ([#49](https://github.com/moneymikeMD/work-order/issues/49)) ([d0656b3](https://github.com/moneymikeMD/work-order/commit/d0656b3b835c19206693a3814d7e21a9cf0b9e43))


### Bug Fixes

* scope reads the repo name from git's main worktree, not the cwd basename (WO-74) ([#51](https://github.com/moneymikeMD/work-order/issues/51)) ([6f446f3](https://github.com/moneymikeMD/work-order/commit/6f446f37fbc8b56a8c745edb172993fd72617b50))

## [1.6.0](https://github.com/moneymikeMD/work-order/compare/v1.5.0...v1.6.0) (2026-09-21)


### Features

* make an unworkable ticket a loud lint error ([625e821](https://github.com/moneymikeMD/work-order/commit/625e8218e534f969ce48a51e4ada80b80af44236))
* register memory and release MCP servers in work-order ([8be145b](https://github.com/moneymikeMD/work-order/commit/8be145bd685dc77b352def8b8b15a0bf5d4a9e03))


### Bug Fixes

* install work-order plugins from moneymike-plugins ([#41](https://github.com/moneymikeMD/work-order/issues/41)) ([1a569a7](https://github.com/moneymikeMD/work-order/commit/1a569a7507d8ac7e0d00d2b2eae8fec1e9753350))
* the prose-contract rule agrees with "none" and stops at triage ([24ce9f9](https://github.com/moneymikeMD/work-order/commit/24ce9f9ebd74fa804df346e8187bcf204f81ba56))

## [1.5.0](https://github.com/moneymikeMD/work-order/compare/v1.4.0...v1.5.0) (2026-09-20)


### Features

* the lifecycle is seven positions, with triage as the entry state ([#36](https://github.com/moneymikeMD/work-order/issues/36)) ([6778a19](https://github.com/moneymikeMD/work-order/commit/6778a1965bf7ee88b4c3484a54d0618f943431a9))

## [1.4.0](https://github.com/moneymikeMD/work-order/compare/v1.3.0...v1.4.0) (2026-09-20)


### Features

* **work-order-jira:** create writes the whole ticket, not just a summary ([#31](https://github.com/moneymikeMD/work-order/issues/31)) ([9a953e3](https://github.com/moneymikeMD/work-order/commit/9a953e3ef1271f25fe30260795bea9d9a4bc61a3))


### Bug Fixes

* **jira:** add the fields to screens before the workflow, and see fields /field hides ([#32](https://github.com/moneymikeMD/work-order/issues/32)) ([172a551](https://github.com/moneymikeMD/work-order/commit/172a551f10042b28c6b7b9e0c6601a8da26cd15e))
* **jira:** create the custom fields before applying the workflow ([#28](https://github.com/moneymikeMD/work-order/issues/28)) ([644ba32](https://github.com/moneymikeMD/work-order/commit/644ba32068d4bf8925d4ea702cc715f4014a460d))

## [1.3.0](https://github.com/moneymikeMD/work-order/compare/v1.2.0...v1.3.0) (2026-09-20)


### Features

* **conformance:** a second validator written without the reference implementation ([#22](https://github.com/moneymikeMD/work-order/issues/22)) ([3431395](https://github.com/moneymikeMD/work-order/commit/3431395f7472613bc46e20b43ee89e84d36c5ae7))
* **conformance:** validate a Jira-tracked set from recorded API responses ([#26](https://github.com/moneymikeMD/work-order/issues/26)) ([7c8b5e0](https://github.com/moneymikeMD/work-order/commit/7c8b5e0409ec1209f469de43298980411cecc914))
* **plugin:** publish the work-order plugin from the repository root ([#25](https://github.com/moneymikeMD/work-order/issues/25)) ([980add8](https://github.com/moneymikeMD/work-order/commit/980add828241031fe47513150068c13d194cb6f2))
* **reference:** tell the wave planner which landing path a wave will use ([#21](https://github.com/moneymikeMD/work-order/issues/21)) ([f9432f6](https://github.com/moneymikeMD/work-order/commit/f9432f62de35d8dae58795a8ce82634ca5bca70f))


### Bug Fixes

* **reference:** strip the repo-name prefix so scope() classifies a single-repo diff ([#24](https://github.com/moneymikeMD/work-order/issues/24)) ([99d6aa3](https://github.com/moneymikeMD/work-order/commit/99d6aa3675557d6139157892a1139193241963c0))

## [1.2.0](https://github.com/moneymikeMD/work-order/compare/v1.1.0...v1.2.0) (2026-09-20)


### Features

* **conformance:** ship the validator and the fixtures that prove it fails ([#19](https://github.com/moneymikeMD/work-order/issues/19)) ([35d3942](https://github.com/moneymikeMD/work-order/commit/35d394299020d80d4b183fbe9efcfa01d18e5446))
* **decision-list:** define the decision-list format and the emit-tickets skill ([#12](https://github.com/moneymikeMD/work-order/issues/12)) ([17fb23b](https://github.com/moneymikeMD/work-order/commit/17fb23b6383a7944a2d45220f6e18d3cf897b257))
* **jira:** ship the Jira binding as its own versioned package ([#14](https://github.com/moneymikeMD/work-order/issues/14)) ([5dd0b93](https://github.com/moneymikeMD/work-order/commit/5dd0b930244839734d443010e99b55c0e6d84699))
* **spec:** document the sprint mechanism as an optional extension ([#11](https://github.com/moneymikeMD/work-order/issues/11)) ([be90458](https://github.com/moneymikeMD/work-order/commit/be90458c1dc04af64d85ccbd41661f8503e2031e))


### Bug Fixes

* **reference:** correct three issues.py jira-mode defects ([#20](https://github.com/moneymikeMD/work-order/issues/20)) ([21a16e1](https://github.com/moneymikeMD/work-order/commit/21a16e19cb5d367a3b7d889686239b1ffa145ce5))
* **reference:** exclude .notes.md progress notes from load_files() ([#18](https://github.com/moneymikeMD/work-order/issues/18)) ([2a7b98e](https://github.com/moneymikeMD/work-order/commit/2a7b98ed3bf9487a64400cba562c399247b72e7e))

## [1.1.0](https://github.com/moneymikeMD/work-order/compare/v1.0.0...v1.1.0) (2026-09-20)


### Features

* publish work-order and work-order-jira as two plugins from one marketplace ([#3](https://github.com/moneymikeMD/work-order/issues/3)) ([465483f](https://github.com/moneymikeMD/work-order/commit/465483f5c5d016d891da649b4f390887422ec53c))


### Bug Fixes

* **release:** keep both plugins pre-1.0 so their initial release is 0.1.0 ([#9](https://github.com/moneymikeMD/work-order/issues/9)) ([4eb14cd](https://github.com/moneymikeMD/work-order/commit/4eb14cdbcda7386c09c2bc2f65240e2a39691cd2))
* **release:** reset both plugin baselines to 0.0.0 so the initial release is 0.1.0 ([#8](https://github.com/moneymikeMD/work-order/issues/8)) ([1465107](https://github.com/moneymikeMD/work-order/commit/1465107e783feaff6ca094c3414283736427b94a))
* **release:** set initial-version 0.1.0 and drop the wrong pre-major flag ([#10](https://github.com/moneymikeMD/work-order/issues/10)) ([4a83ec0](https://github.com/moneymikeMD/work-order/commit/4a83ec002a5c43ee85350860dcd103d15a48f412))

## 1.0.0 (2026-09-20)


### Features

* scaffold the work-order specification repository ([#1](https://github.com/moneymikeMD/work-order/issues/1)) ([bb75bce](https://github.com/moneymikeMD/work-order/commit/bb75bceff97b51438d5feda67ba943697926c4cc))
* **spec:** define the ticket contract, conformance levels and profiles ([#4](https://github.com/moneymikeMD/work-order/issues/4)) ([e81213c](https://github.com/moneymikeMD/work-order/commit/e81213c373cbcf78fc991adbdfb5bf38dc8298d5))
