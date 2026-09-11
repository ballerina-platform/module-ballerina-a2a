# Ballerina A2A Library

[![Build](https://github.com/ballerina-platform/module-ballerina-a2a/actions/workflows/build-timestamped-master.yml/badge.svg?branch=main)](https://github.com/ballerina-platform/module-ballerina-a2a/actions/workflows/build-timestamped-master.yml)
[![codecov](https://codecov.io/gh/ballerina-platform/module-ballerina-a2a/branch/main/graph/badge.svg)](https://codecov.io/gh/ballerina-platform/module-ballerina-a2a)
[![Trivy](https://github.com/ballerina-platform/module-ballerina-a2a/actions/workflows/trivy-scan.yml/badge.svg)](https://github.com/ballerina-platform/module-ballerina-a2a/actions/workflows/trivy-scan.yml)
[![GraalVM Check](https://github.com/ballerina-platform/module-ballerina-a2a/actions/workflows/build-with-bal-test-graalvm.yml/badge.svg)](https://github.com/ballerina-platform/module-ballerina-a2a/actions/workflows/build-with-bal-test-graalvm.yml)
[![GitHub Last Commit](https://img.shields.io/github/last-commit/ballerina-platform/module-ballerina-a2a.svg)](https://github.com/ballerina-platform/module-ballerina-a2a/commits/main)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

## Overview

This module provides a Ballerina client for the [Agent2Agent (A2A) protocol](https://a2a-protocol.org/latest/specification/) v1.0, an open protocol for communication between independent AI agents.

A2A lets an agent discover what another agent can do, delegate work to it, and follow that work as it progresses. An agent publishes an Agent Card describing its skills, transports, and authentication requirements; a client reads that card and talks to the agent over the transport it declares. This module implements the client side of that exchange over the HTTP+JSON binding.

## Issues and projects

Issues and Projects tabs are disabled for this repository as this is part of the Ballerina Library. To report bugs, request new features, start new discussions, view project boards, etc., go to the [Ballerina Library parent repository](https://github.com/ballerina-platform/ballerina-library).
This repository only contains the source code for the module.

## Build from the source

### Prerequisites

1. Download and install Java SE Development Kit (JDK) version 21 (from one of the following locations).

   - [Oracle](https://www.oracle.com/java/technologies/downloads/)
   - [OpenJDK](https://adoptium.net/)

     > **Note:** Set the JAVA_HOME environment variable to the path name of the directory into which you installed JDK.

2. Generate a GitHub access token with read package permissions, then set the following `env` variables:

   ```shell
   export packageUser=<Your GitHub Username>
   export packagePAT=<GitHub Personal Access Token>
   ```

   > **Note:** These are required even for a read-only build. The build resolves the Ballerina distribution and the standard libraries it needs from GitHub Packages, which rejects anonymous requests.

### Build options

Execute the commands below to build from the source.

1. To build the package:

   ```bash
   ./gradlew clean build
   ```

2. To run the tests:

   ```bash
   ./gradlew clean test
   ```

3. To build without the tests:

   ```bash
   ./gradlew clean build -x test
   ```

4. To debug the package with a remote debugger:

   ```bash
   ./gradlew clean build -Pdebug=<port>
   ```

5. To debug with Ballerina language:

   ```bash
   ./gradlew clean build -PbalJavaDebug=<port>
   ```

6. Publish the generated artifacts to the local Ballerina central repository:

   ```bash
   ./gradlew clean build -PpublishToLocalCentral=true
   ```

7. Publish the generated artifacts to the Ballerina central repository:

   ```bash
   ./gradlew clean build -PpublishToCentral=true
   ```

> **Note:** The `io.ballerina.plugin` wires the `commitTomlFiles` task into the build graph itself. On a CI runner that is harmless, since nothing is pushed; locally, a build that changes `Ballerina.toml` or `Dependencies.toml` will commit them onto your current branch without asking. Pass `-x commitTomlFiles` when building locally.

## Contribute to Ballerina

As an open-source project, Ballerina welcomes contributions from the community.

For more information, go to the [contribution guidelines](https://github.com/ballerina-platform/ballerina-lang/blob/master/CONTRIBUTING.md).

## Code of conduct

All the contributors are encouraged to read the [Ballerina Code of Conduct](https://ballerina.io/code-of-conduct).

## Useful links

- For more information go to the [`a2a` library](https://lib.ballerina.io/ballerina/a2a/latest).
- For the protocol itself, see the [A2A specification](https://a2a-protocol.org/latest/specification/).
- Chat live with us via our [Discord server](https://discord.gg/ballerinalang).
- Post all technical questions on Stack Overflow with the [#ballerina](https://stackoverflow.com/questions/tagged/ballerina) tag.
