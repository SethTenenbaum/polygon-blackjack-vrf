// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {VRFRequestLogic} from "./VRFRequestLogic.sol";

/**
 * @title VRFRequestHelper
 * @notice Library to consolidate repetitive VRF request logic
 * @dev Reduces GameUpgradeable bytecode by extracting common patterns
 */
library VRFRequestHelper {
    
    /**
     * @notice Make VRF request and handle common setup
     * @dev Consolidates the pattern used in hit(), doubleDown(), split(), dealerHit()
     * @param factory The factory contract address
     * @param linkToken The LINK token contract
     * @param player The player address
     * @return newRequestId The VRF request ID
     * @return linkFee The LINK fee charged
     */
    function makeVRFRequest(
        address factory,
        IERC20 linkToken,
        address player,
        uint8 /* reqType */
    ) external returns (uint256 newRequestId, uint256 linkFee) {
        // Get link fee
        linkFee = VRFRequestLogic.getLinkFee();
        
        // Request VRF through factory (factory uses its configured gas limit)
        (bool success, bytes memory data) = factory.call(
            abi.encodeWithSignature(
                "requestVRFForGame(uint32)",
                VRFRequestLogic.getNumWords()
            )
        );
        require(success, "VRF request failed");
        newRequestId = abi.decode(data, (uint256));
        
        // Collect LINK fee from player
        require(linkToken.transferFrom(player, address(this), linkFee), "LINK transfer failed");
        
        return (newRequestId, linkFee);
    }
}
