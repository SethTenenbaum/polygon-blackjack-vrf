// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {CardLogic} from "./CardLogic.sol";
import {VRFFulfillmentLogic} from "./VRFFulfillmentLogic.sol";
import {HandProgressionLogic} from "./HandProgressionLogic.sol";

library GameRandomnessLogic {
    
    function handlePlayerHit(
        uint256 random,
        uint8 /* currentHand */
    ) external pure returns (uint8 newCard) {
        newCard = VRFFulfillmentLogic.getCardFromRandom(random);
    }
    
    function handleDealerHit(
        uint256 random
    ) external pure returns (uint8 newCard) {
        newCard = VRFFulfillmentLogic.getCardFromRandom(random);
    }
    
    function handleInitialDeal(
        uint256 random
    ) external pure returns (uint8 card1, uint8 card2, uint8 card3) {
        card1 = VRFFulfillmentLogic.getCardFromRandom(random);
        random >>= 8;
        card2 = VRFFulfillmentLogic.getCardFromRandom(random);
        random >>= 8;
        card3 = VRFFulfillmentLogic.getCardFromRandom(random);
    }
}
