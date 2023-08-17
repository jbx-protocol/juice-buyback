// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IJBPayDelegate3_1_1} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayDelegate3_1_1.sol";
import {IJBFundingCycleDataSource3_1_1} from
    "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleDataSource3_1_1.sol";
import {IJBDirectory} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBDirectory.sol";
import {IJBController3_1} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController3_1.sol";
import {IJBProjects} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBProjects.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

import {IWETH9} from "./external/IWETH9.sol";

interface IJBGenericBuybackDelegate is IJBPayDelegate3_1_1, IJBFundingCycleDataSource3_1_1, IUniswapV3SwapCallback {
    /////////////////////////////////////////////////////////////////////
    //                             Errors                              //
    /////////////////////////////////////////////////////////////////////

    error JuiceBuyback_MaximumSlippage();
    error JuiceBuyback_InsufficientPayAmount();
    error JuiceBuyback_NotEnoughTokensReceived();
    error JuiceBuyback_NewSecondsAgoTooLow();
    error JuiceBuyback_NoProjectToken();
    error JuiceBuyback_PoolAlreadySet();
    error JuiceBuyback_TransferFailed();
    error JuiceBuyback_InvalidTwapDelta();
    error JuiceBuyback_InvalidTwapPeriod();
    error JuiceBuyback_Unauthorized();

    /////////////////////////////////////////////////////////////////////
    //                             Events                              //
    /////////////////////////////////////////////////////////////////////

    event BuybackDelegate_Swap(uint256 indexed projectId, uint256 amountEth, uint256 amountOut);
    event BuybackDelegate_Mint(uint256 indexed projectId);
    event BuybackDelegate_SecondsAgoChanged(uint256 indexed projectId, uint256 oldSecondsAgo, uint256 newSecondsAgo);
    event BuybackDelegate_TwapDeltaChanged(uint256 indexed projectId, uint256 oldTwapDelta, uint256 newTwapDelta);
    event BuybackDelegate_PendingSweep(address indexed beneficiary, address indexed token, uint256 amount);
    event BuybackDelegate_PoolAdded(uint256 indexed projectId, address indexed terminalToken, address newPool);

    /////////////////////////////////////////////////////////////////////
    //                             Getters                             //
    /////////////////////////////////////////////////////////////////////

    function SLIPPAGE_DENOMINATOR() external view returns (uint256);
    function MIN_TWAP_DELTA() external view returns (uint256);
    function MAX_TWAP_DELTA() external view returns (uint256);
    function MIN_SECONDS_AGO() external view returns (uint256);
    function MAX_SECONDS_AGO() external view returns (uint256);
    function UNISWAP_V3_FACTORY() external view returns (address);
    function DIRECTORY() external view returns (IJBDirectory);
    function CONTROLLER() external view returns (IJBController3_1);
    function PROJECTS() external view returns (IJBProjects);
    function WETH() external view returns (IWETH9);
    function delegateId() external view returns (bytes4);
    function poolOf(uint256 _projectId, address _terminalToken) external view returns (IUniswapV3Pool _pool);
    function secondsAgoOf(uint256 _projectId) external view returns (uint32 _seconds);
    function twapDeltaOf(uint256 _projectId) external view returns (uint256 _delta);
    function projectTokenOf(uint256 _projectId) external view returns (address projectTokenOf);

    /////////////////////////////////////////////////////////////////////
    //                    State-changing functions                     //
    /////////////////////////////////////////////////////////////////////

    function setPoolFor(uint256 _projectId, uint24 _fee, uint32 _secondsAgo, uint256 _twapDelta, address _terminalToken)
        external
        returns (IUniswapV3Pool _newPool);

    function changeSecondsAgo(uint256 _projectId, uint32 _newSecondsAgo) external;

    function setTwapDelta(uint256 _projectId, uint256 _newDelta) external;
    function sweep(address _beneficiary, address _token) external;
}
