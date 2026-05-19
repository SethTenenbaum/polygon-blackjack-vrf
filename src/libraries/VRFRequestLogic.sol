// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/**
 * @title VRFRequestLogic
 * @notice Library for VRF configuration constants
 * @dev VRF requests are made through the factory which uses its configured gas limit
 *      This library only provides basic VRF constants, NOT the callback gas limit
 */
library VRFRequestLogic {
    // VRF Configuration for Polygon Amoy Testnet
    bytes32 internal constant KEY_HASH = 0x816bedba8a50b294e5cbd47842baf240c2385f2eaf719edbd4f250a137a8c899;
    uint16 internal constant REQUEST_CONFIRMATIONS = 3;
    uint32 internal constant NUM_WORDS = 1;
    // LINK_FEE: Base premium + estimated gas costs
    // Update this value if Chainlink changes VRF pricing
    // Check: https://docs.chain.link/vrf/v2-5/supported-networks#polygon-amoy-testnet
    // Current: 0.005 LINK provides 10x buffer over minimum
    uint256 internal constant LINK_FEE = 0.005 ether;

    /**
     * @notice Get VRF configuration values (gas limit comes from factory)
     */
    function getVRFConfig() 
        external 
        pure 
        returns (
            bytes32 keyHash,
            uint16 requestConfirmations,
            uint32 numWords,
            uint256 linkFee
        ) 
    {
        return (KEY_HASH, REQUEST_CONFIRMATIONS, NUM_WORDS, LINK_FEE);
    }

    /**
     * @notice Get the LINK fee for a VRF request
     * @return The LINK fee amount
     */
    function getLinkFee() external pure returns (uint256) {
        return LINK_FEE;
    }

    /**
     * @notice Get the key hash for VRF
     */
    function getKeyHash() external pure returns (bytes32) {
        return KEY_HASH;
    }

    /**
     * @notice Get request confirmations
     */
    function getRequestConfirmations() external pure returns (uint16) {
        return REQUEST_CONFIRMATIONS;
    }

    /**
     * @notice Get number of random words
     */
    function getNumWords() external pure returns (uint32) {
        return NUM_WORDS;
    }
}
