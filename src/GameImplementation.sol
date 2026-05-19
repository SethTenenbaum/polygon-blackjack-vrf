// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;
import "./GameUpgradeable.sol";
contract GameImplementation is GameUpgradeable {
    constructor() GameUpgradeable(address(1),1,address(1),address(1),address(1),address(1)) {}
    function initializeClone(
        address _player,
        uint256 _bet,
        address _factory,
        address _gameTokenAddress,
        address _linkAddress
    ) external override {
        require(player == address(0), "Already initialized");
        player = _player;
        bet = _bet;
        factory = _factory;
        createdAt = block.timestamp;
        state = GameState.NotStarted;
        gameToken = IGameToken(_gameTokenAddress);
        linkToken = IERC20(_linkAddress);
        playerHands.push(Hand({cards: new uint8[](0), bet: _bet, stood: false, busted: false, doubled: false}));
    }
}