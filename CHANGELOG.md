# Changelog

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
