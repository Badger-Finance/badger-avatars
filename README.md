# Badger-Avatars
![](./docs/images/badger_logo.png)

# Getting Started

## Prerequisites

- [Foundry](https://github.com/gakonst/foundry)

## Installation

Install and update submodules:

```console
forge install
```

## Compilation

```
forge build
```

## Tests

```
forge test
```

- Use a fixed block number (`--fork-block-number` or `vm.createSelectFork("mainnet", xxx)`) to make tests run faster

## Create a new Avatar
- Create a new folder with your Avatar's name under `src/`
- Copy the [template](./src/template/Avatar.sol) into your folder
- Modify the `name()` function and add your Avatar's name
- Add any custom functions add the end of your Avatar's contract
- Dont't forget to add any required tests!