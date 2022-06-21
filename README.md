# Badger-Avatars
![](./docs/images/badger_logo.png)

# Getting Started

## Prerequisites

- [Foundry](https://github.com/gakonst/foundry)
- [Node.js & NPM](https://nodejs.org/en/)
- [NPX](https://www.npmjs.com/package/npx)

## Installation

Install and update submodules:

```console
git submodule init
git submodule update
```

## Installation

Install linter dependencies:

```console
npm install
```

## Compilation

```
forge build
```

## Tests

Because the tests interact with mainnet contracts, tests must be run in mainnet fork mode.

```
forge test
```

## Create a new Avatar
- Create a new folder with your Avatar's name under `src/avatars/`
- Copy the [template](./src/avatars/template/Avatar.sol) into your folder
- Modify the `getName()` function and add your Avatar's name
- Add any custom functions add the end of your Avatar's contract
- Dont't forget to add any required tests!