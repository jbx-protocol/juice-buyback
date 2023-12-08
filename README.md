# Juicebox Buyback Hook

When a Juicebox project that uses the buyback hook is paid, it checks whether buying tokens in a Uniswap pool or paying the project as usual would yield more tokens for the payer. If buying tokens in the pool would yield more tokens, the payment is routed there. Otherwise, the payment is sent to the project as usual. Either way, the project's reserved rate applies.

The buyback hook works with any Juicebox terminal and checks the Uniswap pool specified by the project's owner.

*If you're having trouble understanding this contract, take a look at the [core Juicebox contracts](https://github.com/bananapus/juice-contracts-v4) and the [documentation](https://docs.juicebox.money/) first. If you have questions, reach out on [Discord](https://discord.com/invite/ErQYmth4dS).*

## Develop

`juice-buyback` uses the [Foundry](https://github.com/foundry-rs/foundry) development toolchain for builds, tests, and deployments. To get set up, install [Foundry](https://github.com/foundry-rs/foundry):

```bash
curl -L https://foundry.paradigm.xyz | sh
```

You can download and install dependencies with:

```bash
forge install
```

If you run into trouble with `forge install`, try using `git submodule update --init --recursive` to ensure that nested submodules have been properly initialized.

Some useful commands:

| Command               | Description                                         |
| --------------------- | --------------------------------------------------- |
| `forge install`       | Install the dependencies.                           |
| `forge build`         | Compile the contracts and write artifacts to `out`. |
| `forge fmt`           | Lint.                                               |
| `forge test`          | Run the tests.                                      |
| `forge build --sizes` | Get contract sizes.                                 |
| `forge coverage`      | Generate a test coverage report.                    |
| `foundryup`           | Update foundry. Run this periodically.              |
| `forge clean`         | Remove the build artifacts and cache directories.   |

To learn more, visit the [Foundry Book](https://book.getfoundry.sh/) docs.

We recommend using [Juan Blanco's solidity extension](https://marketplace.visualstudio.com/items?itemName=JuanBlanco.solidity) for VSCode.

## Utilities

For convenience, several utility commands are available in `util.sh`. To see a list, run:

```bash
`bash util.sh --help`.
```

Or make the script executable and run:

```bash
./util.sh --help
```

## Hooks

This contract is both a *data hook* and a *pay hook*. Data hooks receive information about a payment and put together a payload for the pay hook to execute.

Juicebox projects can specify a data hook in their `JBRulesetMetadata`. When someone attempts to pay or redeem from the project, the project's terminal records the payment in the terminal store, passing information about the payment to the data hook in the process. The data hook responds with a list of payloads – each payload specifies the address of a pay hook, as well as some custom data and an amount of funds to send to that pay hook.

Each pay hook can then execute custom behavior based on the custom data (and funds) they receive.

## Flow

1. The frontend client sends the hook a Uniswap quote, the amount of funds to use for the swap, and the minimum number of project tokens to receive in exchange from the Uniswap pool (accounting for slippage). These should be encoded using the [delegate metadata library](https://github.com/jbx-protocol/juice-delegate-metadata-lib). If no quote is provided, the hook uses a [time-weighted average price](https://blog.uniswap.org/uniswap-v3-oracles#what-is-twap).
2. The terminal's `pay(...)` function calls this buyback hook (as a data hook) to determine whether the swap should be executed or not. It makes this determination by considering the information that was passed in, information about the pool, and the project's current rules.
3. The buyback contract sends its determination back to the terminal. If it approved the swap, the terminal then calls the buyback hook's `didPay(...)` method, which will wrap the ETH (to wETH), execute the swap, burns the token it received, and mints them again (it also mints tokens for any funds which weren't used in the swap, if any). This burning/re-minting process allows the buyback hook to apply the reserved rate and respect the caller's `preferClaimedTokens` preference.
4. If the swap failed (due to exceeding the maximum slippage, low liquidity, or something else) the delegate will mint tokens for the recipient according to the project's rules, and use `addToBalanceOf` to send the funds to the project.

## Risks

- This hook has only been used with terminals that accept ETH so far. It *should* support any ERC-20 terminal, but has not been used for this in production.
- This hook depends on liquidity in a Uniswap v3 pool. If liquidity providers migrate to a new pool, the project's owner has to call `setPoolFor(...)`. If they migrate to a new exchange, this hook won't work.
- If there isn't enough liquidity, or if the max slippage isn't set properly, payers may receive fewer tokens than expected.