#!/bin/bash

if ! command -v forge &> /dev/null
then
    echo "Could not find foundry."
    echo "Please refer to the README.md for installation instructions."
    exit
fi

help_string="Available commands:
  help, -h, --help           - Show this help message
  coverage:lcov              - Generate an LCOV test coverage report.
  deploy:ethereum-mainnet    - Deploy to Ethereum mainnet"

if [ $# -eq 0 ]
then
  echo "$help_string"
  exit
fi

case "$1" in
  "help") echo "$help_string" ;;
  "-h") echo "$help_string" ;;
  "--help") echo "$help_string" ;;
  "coverage:integration") forge coverage --match-path "./src/*.sol" --report lcov --report summary ;;
  "deploy:ethereum-mainnet") source .env && forge script DeployMainnet --rpc-url $MAINNET_RPC_PROVIDER_URL --broadcast --mnemonic-paths mnemonic.txt --verify --etherscan-api-key $ETHERSCAN_API_KEY --sender $SENDER_ADDRESS ;;
  *) echo "Invalid command: $1" ;;
esac

