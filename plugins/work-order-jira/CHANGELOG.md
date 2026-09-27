# Changelog

## [0.7.0](https://github.com/moneymikeMD/work-order/compare/work-order-jira--v0.6.0...work-order-jira--v0.7.0) (2026-09-27)


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

## [0.6.0](https://github.com/moneymikeMD/work-order/compare/work-order-jira--v0.5.1...work-order-jira--v0.6.0) (2026-09-24)


### Features

* blocked_by_external gives a cross-repo blocker a structured home (WO-70) ([#53](https://github.com/moneymikeMD/work-order/issues/53)) ([fe16872](https://github.com/moneymikeMD/work-order/commit/fe1687255f85bf6966e8df6d0eabfeadbd7776a7))

## [0.5.1](https://github.com/moneymikeMD/work-order/compare/work-order-jira--v0.5.0...work-order-jira--v0.5.1) (2026-09-21)


### Bug Fixes

* install work-order plugins from moneymike-plugins ([#41](https://github.com/moneymikeMD/work-order/issues/41)) ([1a569a7](https://github.com/moneymikeMD/work-order/commit/1a569a7507d8ac7e0d00d2b2eae8fec1e9753350))

## [0.5.0](https://github.com/moneymikeMD/work-order/compare/work-order-jira--v0.4.0...work-order-jira--v0.5.0) (2026-09-20)


### Features

* the lifecycle is seven positions, with triage as the entry state ([#36](https://github.com/moneymikeMD/work-order/issues/36)) ([6778a19](https://github.com/moneymikeMD/work-order/commit/6778a1965bf7ee88b4c3484a54d0618f943431a9))

## [0.4.0](https://github.com/moneymikeMD/work-order/compare/work-order-jira--v0.3.0...work-order-jira--v0.4.0) (2026-09-20)


### Features

* **work-order-jira:** create writes the whole ticket, not just a summary ([#31](https://github.com/moneymikeMD/work-order/issues/31)) ([9a953e3](https://github.com/moneymikeMD/work-order/commit/9a953e3ef1271f25fe30260795bea9d9a4bc61a3))


### Bug Fixes

* **jira:** add the fields to screens before the workflow, and see fields /field hides ([#32](https://github.com/moneymikeMD/work-order/issues/32)) ([172a551](https://github.com/moneymikeMD/work-order/commit/172a551f10042b28c6b7b9e0c6601a8da26cd15e))
* **jira:** create the custom fields before applying the workflow ([#28](https://github.com/moneymikeMD/work-order/issues/28)) ([644ba32](https://github.com/moneymikeMD/work-order/commit/644ba32068d4bf8925d4ea702cc715f4014a460d))

## [0.3.0](https://github.com/moneymikeMD/work-order/compare/work-order-jira--v0.2.0...work-order-jira--v0.3.0) (2026-09-20)


### Features

* **conformance:** validate a Jira-tracked set from recorded API responses ([#26](https://github.com/moneymikeMD/work-order/issues/26)) ([7c8b5e0](https://github.com/moneymikeMD/work-order/commit/7c8b5e0409ec1209f469de43298980411cecc914))
* **plugin:** publish the work-order plugin from the repository root ([#25](https://github.com/moneymikeMD/work-order/issues/25)) ([980add8](https://github.com/moneymikeMD/work-order/commit/980add828241031fe47513150068c13d194cb6f2))

## [0.2.0](https://github.com/moneymikeMD/work-order/compare/work-order-jira--v0.1.0...work-order-jira--v0.2.0) (2026-09-20)


### Features

* **jira:** ship the Jira binding as its own versioned package ([#14](https://github.com/moneymikeMD/work-order/issues/14)) ([5dd0b93](https://github.com/moneymikeMD/work-order/commit/5dd0b930244839734d443010e99b55c0e6d84699))

## 0.1.0 (2026-09-20)


### Features

* publish work-order and work-order-jira as two plugins from one marketplace ([#3](https://github.com/moneymikeMD/work-order/issues/3)) ([465483f](https://github.com/moneymikeMD/work-order/commit/465483f5c5d016d891da649b4f390887422ec53c))
