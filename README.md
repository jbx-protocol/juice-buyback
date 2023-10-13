# Juice Buyback Delegate - Terminal token-Project token

## Summary

Provides a datasource and delegate which maximise the project token received by the contributor when they call `pay` on the terminal. In order to do so, the delegate will either mint new tokens ("vanilla" path, bypassing the delegate) and/or swap existing token in an Uniswap V3 pool ("buyback" path), depending on the best quote available at the time of the call as well as the user preferences.

This BBD is used with ETH by JBDAO, this readme hence uses `ETH` as terminal token, but the current implementation allows the use of any ERC20 token as terminal token.

## Design
### Flow
- The frontend passes a quote (as the minimum amount to receive for a given amount send, taking slippage into account) from the correct Uniswap V3, as well as an amount to use for swapping while calling `pay(..)` (this amount might be the less than or equal to the total amount of ETH sent - ie "swap everything or just part of it"). These should be encoded using the [delegate metadata library](https://github.com/jbx-protocol/juice-delegate-metadata-lib). If no quote is provided, a twap is then used.
- `Pay(..)` will use the buyback delegate as datasource and, based on the minmum amount received, the amount to swap and the funding cycle weight, will mint (using the regular terminal flow) and/or swap.
- If swap is needed, the terminal will call the delegate's `didPay` method, which will wrap and swap the eth, burn all the token received and mint them again (with extra-token if a portion of ETH was allocated to minting only). This allows to use the correct reserved rate as well as keep the caller's preference for `preferClaimedTokens`.
- In case of failure of the swap (eg max slippage, low liquidity), the delegate will mint the tokens instead (using the original funding cycle weight and reserved rate, these ETH are then sent back to the project balance using `addToBalanceOf`).

### Contracts/Interfaces
- BuyBackDelegate: the datasource, pay delegate and uniswap pool callback contract
- BuyBackDelegate3.1.1: the buyback delegate leveraging the new terminal v3.1.1

## Usage
Anyone can deploy this delegate using the provided forge script.
To run this repo, you'll need [Foundry](https://book.getfoundry.sh/) and [NodeJS](https://nodejs.dev/en/learn/how-to-install-nodejs/) installed.
Install the dependencies with `npm install && git submodule update --init --force --recursive`, you should then be able to run the tests using `forge test` or deploy a new delegate using `forge script Deploy` (and the correct arguments, based on the chain and key you want to use - see the [Foundry docs](https://book.getfoundry.sh/)).

## Use-case
Maximizing the project token received by the contributor while leveling the funding cycle/secondary market price.

## Risk & trade-offs
 - This delegate is now used with ETH as terminal token, it *should* support any erc20 terminal but hasn't been used in such setup (yet).
 - This delegate relies on the liquidity available in an Uniswap V3. If LP migrate to a new pool or another DEX, this delegate would need to be redeployed.
 - A low liquidity might, if the max slippage isn't set properly, lead to an actual amount of token received lower than expected.

## Future work
- Invariant are only partially tested (total supply hold in mint case, pool needfs additional tooling as we rely on hardcoded pool hash for create2)
- A first version was designed to be used as a BBD for an unique project (project token, pool, etc being immutables), in order to keep the gas cost as low as possible. This might be resumed and further tested if a need arises.
