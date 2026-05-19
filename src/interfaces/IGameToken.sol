// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Extended interface for GameToken with burn capability
 */
interface IGameToken is IERC20 {
    function burn(uint256 amount) external;
}
