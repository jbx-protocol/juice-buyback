# Juice Buyback Delegate

## Motivation

With JBX V3 live now, so going forward we want to give project owners the option of having a buyback delegate which is a delegate which will always take the most advantageous path for users between minting and swapping token project when triggering pay(). 

So as jbx issuance happnes the contributors will have an option to get the jbx with the best quote available on a amm like Uniswap V3

## Mechanic

As the contributors call `pay` on the project's terminal the `payParams` method decides whether the buyback delegate will be used for a `termianl token - project token` i.e `eth-jbx` for the current version. A swap on uniswap v3 is based on whether if the amount of `project token` i.e `jbx` that should be received by the contributor is greater than the `quote` passed in the `metadata` if not the delegate is not used and we follow the `mint` route in the temrinal

On `didPay` assuming the buyback delegate is used if `preferClaimedTokens` is false then we go with the mint route else we swap depending if the slippage at that point isn't too high.

If we go with the swap route so we execute `_swap` and in case the swap fails we again go to the mint route, else once the tokens are swapped then based on the `reserved rate` we first send the `non-reserved` tokens and burn/mint reserved & non-reserved tokens to the delegate, to make sure at the end the token accounting is consistent.

## Architecture

An understanding of how the Juicebox protocol's mechanics & architecture is required

`JBXBuybackDelegate` is the primary contract with all the swap/mint logic based on various conditions explained in the `mechanic` section.


# Install

Quick all-in-one command:

```bash
git clone https://github.com/jbx-protocol/juice-buyback && cd juice-buyback && foundryup && git submodule update --init --recursive --force && yarn install && forge test --gas-report
```

To get set up:

1. Install [Foundry](https://github.com/gakonst/foundry).

```bash
curl -L https://foundry.paradigm.xyz | sh
```

2. Install external lib(s)

```bash
git submodule update --init --recursive --force && yarn install
```

then run

```bash
forge update
```

3. Run tests:

```bash
forge test
```

4. Update Foundry periodically:

```bash
foundryup
```